-- ============================================================================
-- KasihKirim — 0038_seller_dispute_category.sql
--
-- 0032's own audit comments (TEST B5/B6 in 23_dispute_audit_trail.test.sql)
-- documented a real limitation: a seller's only path to OPEN_DISPUTE is the
-- generic public.rpc_delivery_transition, which carries no free-text fields.
-- internal.fn_create_dispute_record coerces that into category='other' plus
-- a generic auto-description -- correct as a safety net for a bare role
-- transition, but it left a seller with no way to say what actually went
-- wrong with their own order (damaged in transit, wrong item picked, a
-- payment/overcharge issue, ...), unlike a customer's rpc_open_dispute
-- (0028/0032), which has always taken a real category and description.
--
-- FIX: a seller-facing counterpart to rpc_open_dispute, same validation and
-- shape, authorized the same way rpc_delivery_transition (0030) already
-- authorizes a seller's bare OPEN_DISPUTE -- ownership via
-- orders.seller_id -> sellers.user_id, not role membership alone. The state
-- machine is unchanged: this is a second entry point into the same
-- internal.fn_create_dispute_record / internal.fn_delivery_transition path
-- rpc_open_dispute already uses, not a new capability.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_open_seller_dispute(
  p_delivery    UUID,
  p_category    TEXT,
  p_description TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  d public.deliveries; k public.kirim_requests;
  v_dispute UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  IF p_category NOT IN ('non_delivery','damaged','wrong_item','not_as_described',
                        'payment','overcharge','conduct','other') THEN
    RAISE EXCEPTION 'INVALID_CATEGORY';
  END IF;
  IF p_description IS NULL OR length(trim(p_description)) < 10 THEN
    RAISE EXCEPTION 'DESCRIPTION_TOO_SHORT';
  END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  -- Ownership: only the seller of THIS order's delivery -- the same check
  -- rpc_delivery_transition (0030) uses to authorize a seller's bare
  -- OPEN_DISPUTE transition. False for a non-PASARAN kirim (k.order_id is
  -- NULL there), same as that check.
  IF NOT EXISTS (SELECT 1 FROM public.orders o
                   JOIN public.sellers s ON s.id = o.seller_id
                  WHERE o.id = k.order_id AND s.user_id = v_uid) THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  -- The escrow window -- identical to rpc_open_dispute's. Before DELIVERED
  -- there is nothing to dispute yet; after settlement the money is gone and
  -- the remedy is an admin refund. DISPUTED is accepted so a seller can still
  -- add their own category/description after a carrier or buyer already
  -- opened the shared dispute record via a bare transition.
  IF d.status NOT IN ('DELIVERED','DISPUTED') THEN
    RAISE EXCEPTION 'DISPUTE_WINDOW_CLOSED';
  END IF;

  IF EXISTS (SELECT 1 FROM public.disputes
              WHERE delivery_id = p_delivery AND resolved_at IS NULL
                AND raised_by = v_uid) THEN
    RAISE EXCEPTION 'DISPUTE_ALREADY_OPEN';
  END IF;

  v_dispute := internal.fn_create_dispute_record(
    p_delivery, v_uid, 'seller'::ref.user_role, p_category, trim(p_description));

  -- Move the delivery only if it is still sitting at DELIVERED; a second
  -- party (carrier/buyer) may already have taken it to DISPUTED --
  -- fn_create_dispute_record has already recorded this filing either way.
  IF d.status = 'DELIVERED' THEN
    PERFORM internal.fn_delivery_transition(
      p_delivery, 'OPEN_DISPUTE', v_uid, 'seller'::ref.user_role,
      'dispute:'||v_dispute::text,
      jsonb_build_object('dispute_id', v_dispute, 'category', p_category,
                         'description', p_description));
  END IF;

  RETURN jsonb_build_object(
    'dispute_id', v_dispute, 'status', 'OPEN',
    'delivery_status', (SELECT status FROM public.deliveries WHERE id = p_delivery),
    'settlement_blocked', internal.fn_settlement_blocked_reason(p_delivery));
END $$;

REVOKE ALL ON FUNCTION public.rpc_open_seller_dispute(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_open_seller_dispute(UUID,TEXT,TEXT) TO authenticated;
