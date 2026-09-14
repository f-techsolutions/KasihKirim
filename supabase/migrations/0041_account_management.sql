-- ============================================================================
-- KasihKirim — 0041_account_management.sql
--
-- Admin account management: search, suspend, ban, restore.
--
-- FINDING (confirmed via grep across every migration through 0040):
-- public.profiles.status (ref.account_status) has only ever been surfaced to
-- the client for display -- custom_access_token_hook (0003) puts it in the
-- JWT's app_metadata.account_status, and ProfileScreen shows it as a badge.
-- Nothing else reads it: no RLS policy, no RPC, no trigger. profiles_update
-- (0003) is owner-only with no admin clause either, so there was previously
-- no way for an admin to even WRITE another user's status, let alone have
-- that write do anything. Suspending or banning an account today would be
-- (or, if the write path existed, would have been) purely cosmetic
-- record-keeping: the account keeps working exactly as before.
--
-- FIX, two parts:
--   1. rpc_admin_set_account_status -- an admin write path, same shape as
--      rpc_admin_set_seller_status/rpc_admin_set_carrier_status (SECURITY
--      DEFINER, since profiles_update's RLS is owner-only and does not admit
--      an admin exception the way products_write etc. do).
--   2. Actual enforcement: custom_access_token_hook now refuses to mint a
--      token at all for a suspended/banned/deleted account. This is the
--      standard Supabase pattern for enforcing an account ban through this
--      hook -- raising inside it fails the sign-in/refresh call itself, so
--      GoTrue never issues a token. Without this, part 1 alone would still
--      be cosmetic.
--
-- Known, accepted latency (same order as the seller/carrier "role only
-- lands at next sign-in" limitation already documented elsewhere in this
-- schema): an access token already issued before a suspension stays valid
-- until it expires (Supabase's default is short-lived, on the order of an
-- hour) -- this closes new sign-ins/refreshes, not already-live sessions.
-- ============================================================================

-- ── 1. Enforcement: refuse to mint a token for a non-active-enough account ──
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_roles text[]; v_meta jsonb; v_uid uuid := (event->>'user_id')::uuid;
  v_status ref.account_status;
BEGIN
  SELECT status INTO v_status FROM public.profiles WHERE id = v_uid;

  -- v_status is NULL for a user with no profiles row yet (e.g. mid-signup,
  -- before tg_auth_users_create_profile has run) -- NULL IN (...) is NULL,
  -- not true, so that case falls through to normal minting unchanged,
  -- exactly as before this migration.
  IF v_status IN ('suspended','banned','deleted') THEN
    RAISE EXCEPTION 'ACCOUNT_NOT_ACTIVE: %', v_status;
  END IF;

  SELECT array_agg(role::text) INTO v_roles
  FROM public.user_roles WHERE user_id = v_uid AND revoked_at IS NULL;

  SELECT jsonb_build_object(
    'roles', COALESCE(to_jsonb(v_roles),'[]'::jsonb),
    'carrier_id', (SELECT id FROM public.carriers WHERE user_id=v_uid AND status='APPROVED'),
    'seller_id',  (SELECT id FROM public.sellers  WHERE user_id=v_uid AND status='APPROVED'),
    'account_status', v_status
  ) INTO v_meta;

  RETURN jsonb_set(event,'{claims,app_metadata}',
    COALESCE(event->'claims'->'app_metadata','{}'::jsonb) || v_meta);
END $$;

-- ── 2. Admin write path ──────────────────────────────────────────────────────
-- Deliberately excludes 'pending' (a pre-activation state, not an admin
-- action) and 'deleted' (the user-initiated deletion flow's own concern,
-- tracked separately via deletion_requested_at/anonymised_at -- an admin
-- forcing that state here would bypass whatever that flow is meant to do).
-- Role membership (seller/carrier/admin_*) is a separate axis from account
-- status in this schema and is left untouched here, same separation
-- rpc_admin_set_seller_status keeps from e.g. product moderation.
CREATE OR REPLACE FUNCTION public.rpc_admin_set_account_status(
  p_user_id UUID, p_status TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_profile public.profiles;
  v_status  ref.account_status;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_status NOT IN ('active','suspended','banned') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;
  v_status := p_status::ref.account_status;

  -- An admin locking out their own account has no recovery path from
  -- inside the app (the same admin console is what they'd need to undo
  -- it), so this is refused outright rather than merely discouraged.
  IF p_user_id = (SELECT auth.uid()) THEN
    RAISE EXCEPTION 'CANNOT_ACT_ON_SELF';
  END IF;

  UPDATE public.profiles SET
    status           = v_status,
    suspended_reason = CASE WHEN v_status IN ('suspended','banned') THEN p_reason ELSE NULL END,
    updated_at       = now()
  WHERE id = p_user_id AND deleted_at IS NULL
  RETURNING * INTO v_profile;

  IF v_profile.id IS NULL THEN RAISE EXCEPTION 'USER_NOT_FOUND'; END IF;

  RETURN jsonb_build_object('user_id', v_profile.id, 'status', v_profile.status);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_set_account_status(UUID,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_account_status(UUID,TEXT,TEXT)
  TO authenticated;
