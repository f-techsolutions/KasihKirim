-- ============================================================================
-- KasihKirim — 0043_admin_order_search_and_ledger_view.sql
--
-- The two remaining Phase 1 (operational infrastructure) items from the
-- completion roadmap: an admin can already approve carriers/sellers, manage
-- accounts and process payouts (0040/0041/0042), but looking up a single
-- order/delivery or checking recent payment activity still means running SQL
-- by hand against production -- exactly the gap Phase 1 exists to close.
--
-- Both RPCs below are read-only and admin-gated. Neither touches schema
-- internal's client grants (still none) or public's RLS (still the same
-- policies) -- they only add two new SECURITY DEFINER windows onto data an
-- admin's own RLS already lets them read piecemeal (kirim_requests,
-- deliveries, orders, profiles all already carry an `OR authz.is_admin()`
-- clause), plus internal.payments, which no client grant can reach at all.
--
-- ── 1. Order/delivery search ────────────────────────────────────────────────
-- One search box, one result: reference codes are UNIQUE on both
-- kirim_requests and orders, so this never needs to render a result list.
-- A HANTAR/BELI reference code is looked up directly; a PASARAN order's own
-- reference code (the one a Jualan buyer was actually shown) is looked up by
-- falling back to public.orders and following its wrapping kirim_request --
-- ck_pasaran_has_order (0001) guarantees a PASARAN order always has one.
-- Returns {"found": false} rather than SQL NULL on no match, so the client
-- never has to special-case decoding a null JSONB body.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_admin_search_order(p_query TEXT)
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  k public.kirim_requests;
  v_order public.orders;
  v_pay internal.payments;
  v_requester JSONB;
  v_deliveries JSONB;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;
  IF trim(coalesce(p_query,'')) = '' THEN RETURN jsonb_build_object('found', false); END IF;

  SELECT * INTO k FROM public.kirim_requests
   WHERE reference_code ILIKE '%'||p_query||'%'
   ORDER BY created_at DESC LIMIT 1;

  IF k.id IS NULL THEN
    SELECT o.* INTO v_order FROM public.orders o
     WHERE o.reference_code ILIKE '%'||p_query||'%'
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_order.id IS NOT NULL THEN
      SELECT * INTO k FROM public.kirim_requests WHERE order_id = v_order.id LIMIT 1;
    END IF;
  END IF;

  IF k.id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;

  IF k.order_id IS NOT NULL AND v_order.id IS NULL THEN
    SELECT * INTO v_order FROM public.orders WHERE id = k.order_id;
  END IF;

  SELECT jsonb_build_object('phone', p.phone, 'full_name', p.full_name, 'display_name', p.display_name)
    INTO v_requester FROM public.profiles p WHERE p.id = k.requester_id;

  -- HANTAR/BELI pay against the kirim itself; PASARAN pays against its order
  -- (fn_settlement_blocked_reason, 0024/0029, reads the same distinction).
  -- COD kirims have no internal.payments row at all -- v_pay staying NULL is
  -- the correct, expected result for those, not a lookup failure.
  SELECT * INTO v_pay FROM internal.payments
   WHERE reference_type='kirim' AND reference_id = k.id
   ORDER BY created_at DESC LIMIT 1;
  IF v_pay.id IS NULL AND k.order_id IS NOT NULL THEN
    SELECT * INTO v_pay FROM internal.payments
     WHERE reference_type='order' AND reference_id = k.order_id
     ORDER BY created_at DESC LIMIT 1;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', d.id,
           'attempt_no', d.attempt_no,
           'status', d.status::text,
           'carrier_name', pr.full_name,
           'carrier_phone', pr.phone,
           'cod_amount_sen', d.cod_amount_sen,
           'carrier_earning_sen', d.carrier_earning_sen,
           'failure_reason', d.failure_reason,
           'matched_at', d.matched_at,
           'picked_up_at', d.picked_up_at,
           'delivered_at', d.delivered_at,
           'completed_at', d.completed_at,
           'has_open_dispute', EXISTS (
             SELECT 1 FROM public.disputes disp
              WHERE disp.delivery_id = d.id AND disp.resolved_at IS NULL)
         ) ORDER BY d.attempt_no), '[]'::jsonb)
    INTO v_deliveries
    FROM public.deliveries d
    JOIN public.carriers c ON c.id = d.carrier_id
    JOIN public.profiles pr ON pr.id = c.user_id
   WHERE d.kirim_id = k.id;

  RETURN jsonb_build_object(
    'found', true,
    'kirim_id', k.id,
    'reference_code', k.reference_code,
    'kirim_type', k.kirim_type::text,
    'status', k.status::text,
    'item_description', k.item_description,
    'est_weight_grams', k.est_weight_grams,
    'budget_cap_sen', k.budget_cap_sen,
    'delivery_fee_sen', k.delivery_fee_sen,
    'commission_sen', k.commission_sen,
    'total_escrow_sen', k.total_escrow_sen,
    'payment_method', k.payment_method::text,
    'created_at', k.created_at,
    'requester', v_requester,
    'order', CASE WHEN v_order.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_order.id,
      'reference_code', v_order.reference_code,
      'status', v_order.status::text,
      'goods_subtotal_sen', v_order.goods_subtotal_sen,
      'delivery_fee_sen', v_order.delivery_fee_sen,
      'discount_sen', v_order.discount_sen,
      'commission_sen', v_order.commission_sen,
      'total_sen', v_order.total_sen,
      'created_at', v_order.created_at
    ) END,
    'payment', CASE WHEN v_pay.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_pay.id,
      'provider', v_pay.provider,
      'method', v_pay.method::text,
      'amount_sen', v_pay.amount_sen,
      'status', v_pay.status::text,
      'failure_code', v_pay.failure_code,
      'created_at', v_pay.created_at
    ) END,
    'deliveries', v_deliveries
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_search_order(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_search_order(TEXT) TO authenticated;

-- ── 2. Recent payments / ledger view ─────────────────────────────────────────
-- Deliberately "basic" per the roadmap's own wording: the platform's most
-- recent payment activity, newest first, payer resolved to a name/phone --
-- not a double-entry ledger browser. internal.ledger_transactions/
-- ledger_entries stay unexposed; internal.payments is the operationally
-- useful surface (did this go through, what failed, how much) for a support
-- admin who isn't trying to audit accounting entries.
CREATE OR REPLACE FUNCTION public.rpc_admin_recent_payments(p_limit INT DEFAULT 50)
RETURNS TABLE (
  id UUID, reference_type TEXT, reference_id UUID, payer_name TEXT, payer_phone TEXT,
  provider TEXT, method TEXT, amount_sen BIGINT, status TEXT, failure_code TEXT,
  created_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  RETURN QUERY
  SELECT p.id, p.reference_type, p.reference_id,
         COALESCE(pr.full_name, pr.display_name), pr.phone,
         p.provider, p.method::text, p.amount_sen, p.status::text, p.failure_code, p.created_at
    FROM internal.payments p
    LEFT JOIN public.profiles pr ON pr.id = p.payer_id
   ORDER BY p.created_at DESC
   LIMIT GREATEST(1, LEAST(p_limit, 200));
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_recent_payments(INT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_recent_payments(INT) TO authenticated;
