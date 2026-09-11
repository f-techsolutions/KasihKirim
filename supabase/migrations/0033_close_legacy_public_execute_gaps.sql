-- ============================================================================
-- KasihKirim — 0033_close_legacy_public_execute_gaps.sql
--
-- FINAL MERGE-READINESS HARDENING: PUBLIC EXECUTE inventory.
--
-- Every `public.*` function was cross-referenced against every REVOKE
-- statement in the migration history (a REVOKE ... FROM PUBLIC is required
-- to remove Postgres's default EXECUTE-to-PUBLIC grant; revoking only from
-- named roles does not touch it). Two pre-existing, pre-P1 functions have
-- never had one, in either 0006 (their own migration) or 0013 (which later
-- redefined rpc_buy_from_lot's body without touching its grants -- CREATE OR
-- REPLACE changes a function's body, never its privileges):
--
--   public.rpc_buy_from_lot(UUID,NUMERIC,TEXT)
--   public.rpc_send_capacity_invite(UUID,TEXT,UUID,UUID,TEXT)
--
-- Both have carried a live PUBLIC EXECUTE grant since creation, reachable by
-- `anon` through PostgREST -- schema `public` IS exposed, unlike `internal`.
--
-- Actual exposure today, checked against each body directly rather than
-- assumed:
--
--   rpc_send_capacity_invite fails closed for anon regardless: it resolves
--   the caller through authz.my_carrier_id(), which is NULL for an
--   unauthenticated session, and raises STATE_ACTOR_NOT_PERMITTED before
--   touching anything. No live hole; revoked here purely to align the grant
--   with the codebase's own stated rule (0005, 0012: "every function here
--   REVOKEs from PUBLIC first").
--
--   rpc_buy_from_lot is the real gap. It reads auth.uid() but never checks
--   it for NULL before using it, unlike every other RPC in this codebase.
--   Reached anonymously today, it would still fail -- internal.fn_marketplace_gate
--   requires ref.compliance_state = 'PRODUCTION_ACTIVE' and
--   ref.feature_gates.muatan_jual_enabled, both off -- and even with Muatan
--   Jual live, the final INSERT INTO public.lot_purchases would abort on
--   buyer_id's NOT NULL constraint, rolling back the whole call including the
--   stock UPDATE that ran first. So no state persists through this path
--   today under any configuration. That is a constraint doing an
--   authorization check's job by accident, not a control -- the fix adds the
--   explicit check every other RPC has, rather than continuing to rely on it.
--
-- Nothing else changes: no new migration for the roughly three dozen
-- pre-P1 `internal.*` functions that also still carry a default PUBLIC
-- grant. Schema `internal` has had no USAGE for anon/authenticated since
-- 0000_prelude.sql, confirmed unchanged by every migration since (grep for
-- any later `GRANT USAGE ON SCHEMA internal` finds none) -- so a PUBLIC
-- EXECUTE grant on a function in that schema is unreachable by any
-- PostgREST-facing role no matter what the function does. Revoking those is
-- real hygiene, tracked as a separate backlog item, not a fix this PR needs
-- to make: sweeping them here would be exactly the "huge unrelated
-- permissions migration" this pass was told not to create.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_buy_from_lot(
  p_lot UUID, p_qty NUMERIC, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  lot public.carrier_stock_lots; v_uid UUID := auth.uid();
  v_goods BIGINT; v_comm BIGINT; v_rate INT; v_purchase public.lot_purchases;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

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

REVOKE ALL ON FUNCTION public.rpc_buy_from_lot(UUID,NUMERIC,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_buy_from_lot(UUID,NUMERIC,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_send_capacity_invite(UUID,TEXT,UUID,UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_send_capacity_invite(UUID,TEXT,UUID,UUID,TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_buy_from_lot(UUID,NUMERIC,TEXT) IS
  'Muatan Jual purchase. Gated on ref.compliance_state and '
  'ref.feature_gates.muatan_jual_enabled (both off); PUBLIC EXECUTE closed '
  'and an explicit UNAUTHENTICATED check added in the final P1 audit.';
