-- ============================================================================
-- KasihKirim — 0037_record_purchase.sql
--
-- Closes a real dead-end found this session: a BELI delivery has no way to
-- leave PROCURING. ref.delivery_transition_rules (seed.sql) has always
-- carried PROCURING --RECORD_PURCHASE--> AWAITING_PICKUP, but no function
-- ever applied it, and DeliveryTransitionRule.kt's own comment already
-- documented why the client left it out: "fn_delivery_transition never
-- applies p_meta to kirim_requests.actual_goods_sen, so a form field for the
-- actual purchase price would silently discard whatever the carrier typed."
--
-- Confirmed before writing this: public.kirim_requests has no UPDATE policy
-- reachable by a carrier at all (only kirim_update_draft, requester-owned,
-- DRAFT-only) -- so this was never a client oversight, it's a genuine
-- missing write path. This RPC is that path: it is the only way
-- actual_goods_sen/goods_receipt_path/goods_purchased_at can be set.
--
-- Scope: the ordinary case where the carrier's actual spend is within
-- budget_cap_sen. tg_kirim_budget_cap (0003, BR-913) already blocks an
-- overspend without an APPROVED public.price_variances row -- this function
-- checks the same condition first for a clean, named error, then relies on
-- the trigger as the real backstop regardless of caller. Raising a variance
-- (RAISE_VARIANCE) needs its own evidence-photo flow and admin approval step
-- and is deliberately out of scope here -- a carrier who overspent without
-- one gets BUDGET_EXCEEDED_NEEDS_VARIANCE, not a stuck delivery, until that
-- flow exists.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_record_purchase(
  p_delivery UUID,
  p_actual_goods_sen BIGINT,
  p_receipt_path TEXT DEFAULT NULL,
  p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  d public.deliveries; k public.kirim_requests; v_new ref.kirim_status;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_actual_goods_sen < 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  -- Only the carrier actually assigned to this delivery, matching the same
  -- ownership check rpc_verify_handover_code (0028) uses.
  IF d.carrier_id IS NULL OR d.carrier_id IS DISTINCT FROM authz.my_carrier_id() THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;
  IF k.kirim_type <> 'BELI' THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION: not applicable to %', k.kirim_type;
  END IF;

  -- Same condition tg_kirim_budget_cap enforces on the UPDATE below -- checked
  -- here first so the client gets a named error instead of a raw
  -- check_violation surfacing from the trigger.
  IF p_actual_goods_sen > k.budget_cap_sen AND NOT EXISTS (
      SELECT 1 FROM public.price_variances v
       WHERE v.kirim_id = k.id AND v.status = 'APPROVED'
         AND v.approved_amount_sen >= p_actual_goods_sen) THEN
    RAISE EXCEPTION 'BUDGET_EXCEEDED_NEEDS_VARIANCE';
  END IF;

  UPDATE public.kirim_requests
     SET actual_goods_sen = p_actual_goods_sen,
         goods_receipt_path = p_receipt_path,
         goods_purchased_at = now(),
         updated_at = now()
   WHERE id = k.id;

  -- STATE_INVALID_TRANSITION here (not PROCURING) is the expected rejection
  -- for a stale/repeated call -- fn_delivery_transition's own rule lookup is
  -- the single source of truth for what state this delivery must be in.
  v_new := internal.fn_delivery_transition(
    p_delivery, 'RECORD_PURCHASE', v_uid, 'carrier'::ref.user_role,
    p_idempotency_key, '{}'::jsonb);

  RETURN jsonb_build_object('status', v_new);
END $$;

REVOKE ALL ON FUNCTION public.rpc_record_purchase(UUID,BIGINT,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_record_purchase(UUID,BIGINT,TEXT,TEXT) TO authenticated;

COMMENT ON FUNCTION public.rpc_record_purchase(UUID,BIGINT,TEXT,TEXT) IS
  'The only write path for kirim_requests.actual_goods_sen/goods_receipt_path -- '
  'closes the BELI PROCURING dead-end. Carrier-only, BELI-only, PROCURING-only '
  '(enforced by ref.delivery_transition_rules via fn_delivery_transition). '
  'An overspend without an approved public.price_variances row is rejected '
  'with BUDGET_EXCEEDED_NEEDS_VARIANCE, backstopped by tg_kirim_budget_cap.';
