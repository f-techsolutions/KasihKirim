-- ============================================================================
-- KasihKirim — 0049_muatan_jual_settlement.sql
--
-- Closes the gap 0013's own comment flagged: "lot_purchases is the snapshot
-- a future settlement RPC will read once that payment mechanism exists,
-- not a payment record itself." rpc_buy_from_lot only ever reserved stock
-- (carrier_stock_lots.qty_reserved) and recorded intent (lot_purchases) --
-- nothing ever converted a reservation into a completed sale, nothing ever
-- moved qty_sold, and nothing ever posted a sen to internal.ledger_*.
--
-- The payment mechanism this needed is not new. A Muatan Jual sale is a
-- carrier physically handing goods to a buyer and collecting cash on the
-- spot -- the exact real-world event internal.fn_record_cod_collection
-- (0004) already models for a Kirim/Jualan COD delivery ("cash exists in
-- the world before it exists in the system"). This reuses that same trust
-- model (a carrier's own declaration, no card or gateway involved) and the
-- same accounts (CARRIER_CASH_RECEIVABLE, carriers.cod_held_sen,
-- internal.fn_remit_cod's existing remittance sweep) rather than inventing
-- a second cash-collection mechanism, then settles per
-- ADDENDUM-COMMERCE.md §5.4's own worked example: the sale itself (escrow
-- in, commission + carrier payable out) and cost of goods sold (carrier
-- payable out, carrier inventory out) as two more entries in the same
-- transaction. Escrow is credited and debited within the same call rather
-- than held open across a delay, because unlike a Kirim/Jualan delivery
-- (days between checkout and drop-off) the collection and the sale are
-- one atomic physical event here -- there is nothing for it to hold.
--
-- carrier_stock_lots.qty_sold has been dead since 0006 (nothing ever wrote
-- it) -- internal.fn_expire_lots (0006) already reads it to compute a
-- perishable write-down, so leaving it permanently 0 meant every expiring
-- lot was written down as if not one unit had ever sold, even a fully
-- reconciled one. This RPC is also the fix for that.
--
-- Still dormant: gated by internal.fn_marketplace_gate(checkout := true),
-- the same call rpc_buy_from_lot itself already makes, which stays closed
-- until MJ-01 (escrow vs BNM, MUATAN-JUAL-COMPLIANCE.md §8/§14, "blocks
-- everything monetary") is resolved. Nothing here can run before that
-- regardless of what a client sends.
-- ============================================================================

/** The carrier's own confirmation that one lot_purchases reservation was
 *  physically handed over and paid for. Settles the whole reservation at
 *  once -- lot_purchases is a snapshot of a single reservation event, not
 *  a running total a partial handover could subtract from. */
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

  SELECT * INTO v_purchase FROM public.lot_purchases WHERE id = p_purchase;
  IF NOT FOUND THEN RAISE EXCEPTION 'PURCHASE_NOT_FOUND'; END IF;
  IF v_purchase.carrier_id <> v_carrier_id THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO lot FROM public.carrier_stock_lots WHERE id = v_purchase.lot_id FOR UPDATE;
  PERFORM internal.fn_marketplace_gate(
    p_category := lot.category_id, p_seller := lot.seller_id, p_checkout := true);

  -- Idempotent the same way fn_settle_delivery is: a retried confirm (poor
  -- rural connectivity, docs/ANDROID.md §1) or a genuine double-tap returns
  -- the already-settled outcome instead of posting twice.
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

  -- Same average-cost formula internal.fn_expire_lots (0006) already uses
  -- for a write-down: this lot's own share of its total cost basis.
  v_cogs := (lot.cost_basis_sen * v_purchase.qty / lot.qty_total)::bigint;

  -- FR-448 / ck_carrier_exposure: the cash just collected raises exposure,
  -- the inventory it came from leaving stock lowers it, in the same breath.
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

  -- Collection: cash exists in the world before it exists in the system --
  -- internal.fn_record_cod_collection's own comment, same accounts.
  PERFORM internal.fn_post(v_txn, 'CARRIER_CASH_RECEIVABLE:'||v_carrier_id, 'DEBIT',  v_purchase.goods_sen);
  PERFORM internal.fn_post(v_txn, 'ESCROW_HELD_DELIVERY', 'CREDIT', v_purchase.goods_sen);

  -- The sale (ADDENDUM-COMMERCE.md §5.4, first entry).
  PERFORM internal.fn_post(v_txn, 'ESCROW_HELD_DELIVERY', 'DEBIT',  v_purchase.goods_sen);
  PERFORM internal.fn_post(v_txn, 'PLATFORM_COMMISSION', 'CREDIT', v_purchase.commission_sen);
  PERFORM internal.fn_post(v_txn, 'CARRIER_PAYABLE:'||v_carrier_id, 'CREDIT', v_purchase.carrier_sen);

  -- Cost of goods sold (ADDENDUM-COMMERCE.md §5.4, second entry).
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

REVOKE ALL ON FUNCTION public.rpc_confirm_lot_handover(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_confirm_lot_handover(UUID) TO authenticated;
