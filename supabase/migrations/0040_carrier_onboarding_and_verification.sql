-- ============================================================================
-- KasihKirim — 0040_carrier_onboarding_and_verification.sql
--
-- 0016's own comment flagged this: "Mirrors the same pre-existing gap on the
-- carrier side (rpc_apply_carrier doesn't exist either)" -- confirmed still
-- true (grepped every migration through 0039): public.carriers has no INSERT
-- policy and no apply RPC, so a user has no self-service way to become a
-- carrier at all. Unlike sellers, this gap was never closed -- Android's
-- carrier screens (Board/Trips/Vehicles/Deliveries/Earnings) all assume a
-- carriers row and the carrier role already exist, with no path shown here
-- for how either gets created.
--
-- FIX: the carrier-side counterpart to 0016's rpc_apply_seller and 0023's
-- rpc_admin_set_seller_status, same shape, same two-write invariant (the
-- status column and the 'carrier' role grant/revoke must move together,
-- since the client reads its carrier id from the JWT's carrier_id claim --
-- custom_access_token_hook, 0003 -- built from carriers.status='APPROVED').
-- carriers_select's RLS (0003) already lets an admin read every carrier at
-- any status ("OR authz.is_admin()"), so no separate queue-reader RPC is
-- needed here either, mirroring 0023's own reasoning for sellers.
-- ============================================================================

-- ── 1. Somewhere to put the reviewer's reason, mirroring sellers.review_note (0023) ──
ALTER TABLE public.carriers ADD COLUMN IF NOT EXISTS review_note TEXT;

-- ── 2. Self-service carrier application ──────────────────────────────────────
-- Deliberately minimal, mirroring rpc_apply_seller's own scope: only
-- home_community_id is meaningful applicant input at this stage. tier,
-- float_limit_sen and max_detour_km are risk parameters an admin sets (or
-- leaves at their safe defaults), not something a new applicant chooses for
-- themselves. Vehicle registration stays a separate, existing flow
-- (VehiclesScreen/vehicles_own RLS) -- it already works for a carrier at any
-- status, since vehicles_own gates on carrier_id, not carrier status.
CREATE OR REPLACE FUNCTION public.rpc_apply_carrier(p_home_community_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_carrier public.carriers;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  IF EXISTS (SELECT 1 FROM public.carriers WHERE user_id = v_uid) THEN
    RAISE EXCEPTION 'CARRIER_APPLICATION_EXISTS';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.communities WHERE id = p_home_community_id) THEN
    RAISE EXCEPTION 'COMMUNITY_NOT_FOUND';
  END IF;

  INSERT INTO public.carriers (user_id, home_community_id, status)
  VALUES (v_uid, p_home_community_id, 'NOT_STARTED')
  RETURNING * INTO v_carrier;

  -- Granting the 'carrier' role itself and moving status past NOT_STARTED is
  -- an admin-console action, the same boundary rpc_apply_seller (0016) keeps.
  RETURN jsonb_build_object('carrier_id', v_carrier.id, 'status', v_carrier.status);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_apply_carrier(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_apply_carrier(UUID) TO authenticated;

-- ── 3. Carrier verification review ───────────────────────────────────────────
-- Byte-for-byte the same shape as rpc_admin_set_seller_status (0023): same
-- status subset (an applicant can't self-serve into UNDER_REVIEW or straight
-- to APPROVED), same verified_at-set-once-on-APPROVED, same role grant/revoke
-- done in the same transaction as the status write.
CREATE OR REPLACE FUNCTION public.rpc_admin_set_carrier_status(
  p_carrier_id UUID, p_status TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_carrier public.carriers;
  v_status  ref.verification_status;
  v_actor   UUID := (SELECT id FROM public.profiles WHERE id = (SELECT auth.uid()));
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_status NOT IN ('UNDER_REVIEW','MORE_INFO_REQUIRED','APPROVED',
                      'REJECTED','SUSPENDED','REVOKED') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;
  v_status := p_status::ref.verification_status;

  UPDATE public.carriers SET
    status      = v_status,
    review_note = COALESCE(p_reason, review_note),
    verified_at = CASE WHEN v_status = 'APPROVED'
                       THEN COALESCE(verified_at, now()) ELSE verified_at END,
    updated_at  = now()
  WHERE id = p_carrier_id
  RETURNING * INTO v_carrier;

  IF v_carrier.id IS NULL THEN RAISE EXCEPTION 'CARRIER_NOT_FOUND'; END IF;

  -- Same reason rpc_admin_set_seller_status does both writes in one function:
  -- the client reads its carrier_id from the JWT (custom_access_token_hook),
  -- built from carriers.status='APPROVED' -- an APPROVED row with no role
  -- grant leaves the carrier unable to reach a single carrier screen, and a
  -- REVOKED row whose grant still stands leaves them able to reach all of them.
  IF v_status = 'APPROVED' THEN
    INSERT INTO public.user_roles (user_id, role, granted_by)
    VALUES (v_carrier.user_id, 'carrier', v_actor)
    ON CONFLICT (user_id, role) DO UPDATE
      SET revoked_at = NULL, granted_at = now(), granted_by = v_actor;
  ELSIF v_status IN ('REJECTED','SUSPENDED','REVOKED') THEN
    UPDATE public.user_roles SET revoked_at = now()
     WHERE user_id = v_carrier.user_id AND role = 'carrier' AND revoked_at IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'carrier_id', v_carrier.id,
    'status',     v_carrier.status,
    -- The grant only reaches the carrier's session when their token is next
    -- minted, same as the seller console's own notice tells the reviewer.
    'role_active', v_status = 'APPROVED');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_set_carrier_status(UUID,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_carrier_status(UUID,TEXT,TEXT)
  TO authenticated;
