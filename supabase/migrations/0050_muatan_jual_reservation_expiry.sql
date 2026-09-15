-- ============================================================================
-- KasihKirim — 0050_muatan_jual_reservation_expiry.sql
--
-- A gap 0049's own settlement RPC exposed rather than closed: rpc_buy_from_lot
-- bumps carrier_stock_lots.qty_reserved the moment a buyer reserves stock,
-- but nothing ever released it if the buyer never showed up and the carrier
-- never called rpc_confirm_lot_handover. A single no-show would permanently
-- lock that quantity away from every other buyer on the corridor, forever --
-- the lot's own qty_total ratchets down with no way back except a carrier
-- withdrawing and re-creating the whole lot.
--
-- internal.fn_release_stale_lot_reservations() closes it: a lot_purchases
-- row older than ref.app_config's own lot_reservation_ttl_hours (the same
-- key-per-duration convention handover_code_ttl_hours already uses, 0028)
-- and never settled has its qty_reserved released back and is marked
-- expired_at so rpc_confirm_lot_handover can no longer act on it.
--
-- Not scheduled via pg_cron here, deliberately matching internal.fn_expire_
-- lots' own unscheduled state (0006) -- both are Muatan Jual maintenance
-- sweeps for a feature nothing can reach yet (ref.compliance_state stays
-- NOT_READY), so scheduling either is real go-live work, not something to
-- do ahead of it. Whoever throws that switch adds both to seed.sql's own
-- cron.schedule block in the same pass.
-- ============================================================================

ALTER TABLE public.lot_purchases ADD COLUMN expired_at TIMESTAMPTZ;

INSERT INTO ref.app_config (key, value, description) VALUES
  ('lot_reservation_ttl_hours', '24',
   'How long an unconfirmed Muatan Jual reservation holds stock before internal.fn_release_stale_lot_reservations releases it back')
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION internal.fn_release_stale_lot_reservations()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ttl_hours INT;
  v_purchase public.lot_purchases;
  n INT := 0;
BEGIN
  SELECT (value#>>'{}')::int INTO v_ttl_hours
    FROM ref.app_config WHERE key = 'lot_reservation_ttl_hours';

  FOR v_purchase IN
    SELECT lp.* FROM public.lot_purchases lp
     WHERE lp.expired_at IS NULL
       AND lp.created_at < now() - (v_ttl_hours || ' hours')::interval
       AND NOT EXISTS (SELECT 1 FROM internal.ledger_transactions t
                        WHERE t.idempotency_key = 'lot_settle:'||lp.id::text)
     ORDER BY lp.created_at
  LOOP
    -- Re-check under lock: a concurrent rpc_confirm_lot_handover may have
    -- settled this exact reservation between the scan above and now (that
    -- RPC takes the same lock on this row before its own settled check).
    PERFORM 1 FROM public.lot_purchases WHERE id = v_purchase.id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM internal.ledger_transactions
                WHERE idempotency_key = 'lot_settle:'||v_purchase.id::text) THEN
      CONTINUE;
    END IF;

    UPDATE public.carrier_stock_lots
       SET qty_reserved = GREATEST(0, qty_reserved - v_purchase.qty), updated_at = now()
     WHERE id = v_purchase.lot_id;
    UPDATE public.lot_purchases SET expired_at = now() WHERE id = v_purchase.id;
    n := n + 1;
  END LOOP;

  RETURN n;
END $$;

/** rpc_confirm_lot_handover (0049), updated: refuses a reservation that
 *  internal.fn_release_stale_lot_reservations already released, and takes
 *  FOR UPDATE on the purchase row itself (it already took it on the lot)
 *  so the two functions can never race on the same reservation. */
CREATE OR REPLACE FUNCTION public.rpc_confirm_lot_handover(p_purchase UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_carrier_id UUID := authz.my_carrier_id();
  v_purchase public.lot_purchases;
  lot public.carrier_stock_lots;
  v_carrier public.carriers;
  v_txn UUID;
  v_cogs BIGINT;
BEGIN
  IF v_carrier_id IS NULL THEN RAISE EXCEPTION 'NOT_A_CARRIER'; END IF;

  SELECT * INTO v_purchase FROM public.lot_purchases WHERE id = p_purchase FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_NOT_FOUND'; END IF;
  IF v_purchase.carrier_id <> v_carrier_id THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;
  IF v_purchase.expired_at IS NOT NULL THEN RAISE EXCEPTION 'RESERVATION_EXPIRED'; END IF;

  SELECT * INTO lot FROM public.carrier_stock_lots WHERE id = v_purchase.lot_id FOR UPDATE;
  PERFORM internal.fn_marketplace_gate(
    p_category := lot.category_id, p_seller := lot.seller_id, p_checkout := true);

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('LOT_SALE_SETTLEMENT', 'lot_purchase', p_purchase,
          'lot_settle:'||p_purchase::text, 'Muatan Jual sale settled')
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_txn;
  IF v_txn IS NULL THEN
    RETURN jsonb_build_object('purchase_id', p_purchase, 'status', 'ALREADY_SETTLED');
  END IF;

  SELECT * INTO v_carrier FROM public.carriers WHERE id = v_carrier_id FOR UPDATE;

  v_cogs := (lot.cost_basis_sen * v_purchase.qty / lot.qty_total)::bigint;

  IF v_carrier.cod_held_sen + v_carrier.procurement_advance_sen
     + GREATEST(0, v_carrier.inventory_at_risk_sen - v_cogs) + v_purchase.goods_sen
     > v_carrier.float_limit_sen THEN
    RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED';
  END IF;

  UPDATE public.carrier_stock_lots
     SET qty_reserved = qty_reserved - v_purchase.qty,
         qty_sold     = qty_sold + v_purchase.qty,
         updated_at   = now()
   WHERE id = lot.id;

  PERFORM internal.fn_post(v_txn, 'CARRIER_CASH_RECEIVABLE:'||v_carrier_id, 'DEBIT',  v_purchase.goods_sen);
  PERFORM internal.fn_post(v_txn, 'ESCROW_HELD_DELIVERY', 'CREDIT', v_purchase.goods_sen);

  PERFORM internal.fn_post(v_txn, 'ESCROW_HELD_DELIVERY', 'DEBIT',  v_purchase.goods_sen);
  PERFORM internal.fn_post(v_txn, 'PLATFORM_COMMISSION', 'CREDIT', v_purchase.commission_sen);
  PERFORM internal.fn_post(v_txn, 'CARRIER_PAYABLE:'||v_carrier_id, 'CREDIT', v_purchase.carrier_sen);

  IF v_cogs > 0 THEN
    PERFORM internal.fn_post(v_txn, 'CARRIER_PAYABLE:'||v_carrier_id, 'DEBIT', v_cogs);
    PERFORM internal.fn_post(v_txn, 'CARRIER_INVENTORY:'||v_carrier_id, 'CREDIT', v_cogs);
  END IF;

  UPDATE public.carriers
     SET cod_held_sen = cod_held_sen + v_purchase.goods_sen,
         inventory_at_risk_sen = GREATEST(0, inventory_at_risk_sen - v_cogs)
   WHERE id = v_carrier_id;

  RETURN jsonb_build_object(
    'purchase_id', p_purchase, 'status', 'SETTLED',
    'goods_sen', v_purchase.goods_sen, 'commission_sen', v_purchase.commission_sen,
    'carrier_sen', v_purchase.carrier_sen, 'cost_of_goods_sen', v_cogs);
END $$;
