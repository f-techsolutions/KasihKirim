-- ============================================================================
-- KasihKirim — 0039_carrier_dispute_category.sql
--
-- ref.delivery_transition_rules has always permitted a carrier to fire
-- DELIVERED --OPEN_DISPUTE--> DISPUTED (seeded since day one, for all three
-- kirim_type), but nothing in this client has ever offered it: no button, no
-- generic rpc_delivery_transition("OPEN_DISPUTE") button in
-- DeliveryTransitionRule.kt (0037's own comment on that file already
-- explains why RECORD_PURCHASE needs a dedicated flow instead of a plain
-- button -- OPEN_DISPUTE for a carrier needs one for the same reason: a
-- category and description, not a bare fire-and-forget event). A carrier
-- who received damaged goods, was shorted on COD, or hit any other genuine
-- problem with a delivery had no in-app way to raise it at all.
--
-- FIX: a carrier-facing counterpart to rpc_open_dispute/rpc_open_seller_dispute
-- (0038), same validation and shape, authorized by the same ownership check
-- rpc_delivery_transition (0030) already uses for a carrier's own delivery --
-- d.carrier_id = authz.my_carrier_id(), not role membership alone. Unlike the
-- seller path, this applies to all three kirim_type (BELI, HANTAR, PASARAN),
-- matching the seed rule's own applies_to_types.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_open_carrier_dispute(
  p_delivery    UUID,
  p_category    TEXT,
  p_description TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  d public.deliveries;
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

  -- Ownership: only the carrier assigned to THIS delivery -- the same check
  -- rpc_delivery_transition (0030) uses to authorize a carrier's bare
  -- OPEN_DISPUTE transition.
  IF d.carrier_id IS NULL OR d.carrier_id IS DISTINCT FROM authz.my_carrier_id() THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  -- The escrow window -- identical to rpc_open_dispute's/
  -- rpc_open_seller_dispute's. DISPUTED is accepted so a carrier can still
  -- add their own category/description after a buyer or seller already
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
    p_delivery, v_uid, 'carrier'::ref.user_role, p_category, trim(p_description));

  -- Move the delivery only if it is still sitting at DELIVERED; a second
  -- party (buyer/seller) may already have taken it to DISPUTED --
  -- fn_create_dispute_record has already recorded this filing either way.
  IF d.status = 'DELIVERED' THEN
    PERFORM internal.fn_delivery_transition(
      p_delivery, 'OPEN_DISPUTE', v_uid, 'carrier'::ref.user_role,
      'dispute:'||v_dispute::text,
      jsonb_build_object('dispute_id', v_dispute, 'category', p_category,
                         'description', p_description));
  END IF;

  RETURN jsonb_build_object(
    'dispute_id', v_dispute, 'status', 'OPEN',
    'delivery_status', (SELECT status FROM public.deliveries WHERE id = p_delivery),
    'settlement_blocked', internal.fn_settlement_blocked_reason(p_delivery));
END $$;

REVOKE ALL ON FUNCTION public.rpc_open_carrier_dispute(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_open_carrier_dispute(UUID,TEXT,TEXT) TO authenticated;
