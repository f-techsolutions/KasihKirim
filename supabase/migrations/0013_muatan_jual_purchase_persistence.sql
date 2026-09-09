-- ============================================================================
-- KasihKirim — 0013_muatan_jual_purchase_persistence.sql
--
-- Closes two gaps in public.rpc_buy_from_lot (0006), both found the same way:
-- reading the function's actual current body against what it's supposed to
-- guarantee, not assuming the original 0006 implementation still holds.
--
--   1. Dead compliance gate. rpc_buy_from_lot's only check was
--      `(value->>'muatan_jual')::boolean FROM ref.app_config WHERE
--      key='feature_flags'` -- but 0007 replaced that key's value with
--      `{"see":"ref.feature_gates"}` and left the real flags in the new
--      ref.feature_gates / ref.compliance_state tables (see 0007's
--      internal.fn_marketplace_gate). `value->>'muatan_jual'` against the
--      pointer object is NULL, `NULL::boolean` is NULL, and `IF NOT NULL`
--      never fires in PL/pgSQL -- so the guard has been silently inert since
--      0007 ran. supabase/tests/06_commerce.test.sql's own comment already
--      flagged this ("the old key now holds a pointer, so value->>'muatan_jual'
--      was NULL. Read the live source.") but the RPC itself was never fixed
--      to match; the test just started asserting against ref.feature_gates
--      directly instead of exercising the RPC's own guard. Fixed by calling
--      internal.fn_marketplace_gate(category, seller, checkout := true) --
--      checkout := true because this RPC IS the "customer money movement"
--      action muatan_jual_checkout_enabled exists to gate.
--   2. No persistence. The RPC bumped carrier_stock_lots.qty_reserved and
--      returned a JSONB blob, but recorded nowhere who reserved what, and
--      silently ignored its own p_idempotency_key parameter -- a retried
--      request (the normal case on the rural/3G connections this app
--      targets, per docs/ANDROID.md §1) would double-reserve. Fixed by
--      public.lot_purchases: one row per reservation, checked for a replay
--      by idempotency_key before any side effect, mirroring
--      internal.fn_delivery_transition's existing replay pattern (0003).
--
-- What this does NOT do, deliberately: post anything to internal.ledger_*.
-- No real payment is collected here -- muatan_jual_checkout_enabled stays
-- closed until MJ-01's escrow-vs-BNM question is answered (0007's own
-- comment on that gate), the same reason Muatan Jual ships browse-only in
-- KasihKirimAndroid/ today. The ledger only ever records money the platform
-- actually holds (see internal.fn_settle_delivery, 0003, which posts nothing
-- until a delivery completes) -- lot_purchases is the snapshot a future
-- settlement RPC will read once that payment mechanism exists, not a
-- payment record itself.
-- ============================================================================

CREATE TABLE public.lot_purchases (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  lot_id             UUID NOT NULL REFERENCES public.carrier_stock_lots(id) ON DELETE RESTRICT,
  buyer_id           UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  carrier_id         UUID NOT NULL REFERENCES public.carriers(id) ON DELETE RESTRICT,
  qty                NUMERIC(10,2) NOT NULL CHECK (qty > 0),
  price_per_unit_sen BIGINT NOT NULL CHECK (price_per_unit_sen > 0),
  goods_sen          BIGINT NOT NULL CHECK (goods_sen >= 0),
  commission_sen     BIGINT NOT NULL CHECK (commission_sen >= 0),
  carrier_sen        BIGINT NOT NULL CHECK (carrier_sen >= 0),
  idempotency_key    TEXT UNIQUE,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_lot_purchase_split CHECK (goods_sen = commission_sen + carrier_sen)
);
CREATE INDEX ix_lot_purchases_buyer   ON public.lot_purchases(buyer_id, created_at DESC);
CREATE INDEX ix_lot_purchases_carrier ON public.lot_purchases(carrier_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.rpc_buy_from_lot(
  p_lot UUID, p_qty NUMERIC, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  lot public.carrier_stock_lots; v_uid UUID := auth.uid();
  v_goods BIGINT; v_comm BIGINT; v_rate INT; v_purchase public.lot_purchases;
BEGIN
  IF p_idempotency_key IS NOT NULL THEN
    SELECT * INTO v_purchase FROM public.lot_purchases
     WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
      RETURN jsonb_build_object(
        'lot_id', v_purchase.lot_id, 'qty', v_purchase.qty,
        'goods_sen', v_purchase.goods_sen, 'commission_sen', v_purchase.commission_sen,
        'carrier_sen', v_purchase.carrier_sen, 'purchase_id', v_purchase.id);
    END IF;
  END IF;

  SELECT * INTO lot FROM public.carrier_stock_lots WHERE id = p_lot FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LOT_UNAVAILABLE'; END IF;

  PERFORM internal.fn_marketplace_gate(
    p_category := lot.category_id, p_seller := lot.seller_id, p_checkout := true);

  IF lot.status <> 'ACTIVE' THEN RAISE EXCEPTION 'LOT_UNAVAILABLE'; END IF;
  IF lot.sell_by IS NOT NULL AND lot.sell_by < now() THEN
    RAISE EXCEPTION 'LOT_EXPIRED'; END IF;
  -- BR-910: a carrier cannot buy their own stock.
  IF EXISTS (SELECT 1 FROM public.carriers c
             WHERE c.id = lot.carrier_id AND c.user_id = v_uid) THEN
    RAISE EXCEPTION 'SELF_DEALING'; END IF;

  IF lot.qty_reserved + lot.qty_sold + p_qty > lot.qty_total THEN
    RAISE EXCEPTION 'CAPACITY_EXCEEDED';   -- ck_lot_not_oversold backs this up
  END IF;

  v_goods := (lot.price_per_unit_sen * p_qty)::bigint;

  SELECT rate_bps INTO v_rate FROM internal.commission_rules
   WHERE context='muatan_jual' AND basis='goods_subtotal' AND effective_to IS NULL
   ORDER BY effective_from DESC LIMIT 1;
  v_comm := v_goods * v_rate / 10000;      -- 10% on goods

  UPDATE public.carrier_stock_lots
     SET qty_reserved = qty_reserved + p_qty, updated_at = now()
   WHERE id = p_lot;

  INSERT INTO public.lot_purchases
    (lot_id, buyer_id, carrier_id, qty, price_per_unit_sen,
     goods_sen, commission_sen, carrier_sen, idempotency_key)
  VALUES
    (p_lot, v_uid, lot.carrier_id, p_qty, lot.price_per_unit_sen,
     v_goods, v_comm, v_goods - v_comm, p_idempotency_key)
  RETURNING * INTO v_purchase;

  RETURN jsonb_build_object(
    'lot_id', p_lot, 'qty', p_qty,
    'goods_sen', v_goods, 'commission_sen', v_comm,
    'carrier_sen', v_goods - v_comm,
    'qty_remaining', lot.qty_total - lot.qty_reserved - lot.qty_sold - p_qty,
    'purchase_id', v_purchase.id);
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- RLS — same "append-only via the server action" pattern as delivery_events
-- and inventory_movements: reads are policy-scoped, writes are closed to
-- everyone but rpc_buy_from_lot (SECURITY DEFINER).
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.lot_purchases ENABLE ROW LEVEL SECURITY;

CREATE POLICY lot_purchases_select ON public.lot_purchases FOR SELECT TO authenticated
  USING (buyer_id = (SELECT auth.uid())
         OR carrier_id = authz.my_carrier_id()
         OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.lot_purchases FROM authenticated, anon;

GRANT SELECT ON public.lot_purchases TO authenticated;
