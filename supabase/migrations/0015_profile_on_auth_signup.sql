-- ============================================================================
-- KasihKirim — 0015_profile_on_auth_signup.sql
--
-- Closes a gap the implementation audit found and this migration verifies
-- directly against the live database rather than assuming: zero non-internal
-- triggers exist on auth.users (confirmed via pg_trigger), despite
-- 0002_supporting_entities.sql's own ordering note describing one
-- ("4. auth.users trigger -> public.profiles"). It was never implemented.
--
-- Confirmed live before writing this migration: one real, currently
-- unconfirmed signup (a genuine user, not a fixture) already has no profiles
-- row. Every table that FKs to profiles(id) fails on that user's first
-- write -- concretely, for this app's own write paths,
-- addresses.user_id -> profiles(id) (AddressRepositoryImpl.createAddress)
-- and kirim_requests.requester_id -> profiles(id) (rpc_create_kirim).
--
-- A second, distinct gap this migration also fixes: profiles.phone is
-- NOT NULL with no default, and email/password signup -- the only signup
-- method this app has (confirmed by reading AuthRepositoryImpl.
-- signUpWithEmail, which passes only email and password to
-- signUpWith(Email)) -- never collects a phone number. Even a trivial
-- profile-creation trigger would still fail on that NOT NULL without also
-- relaxing it.
-- ============================================================================

-- 1. profiles.phone must be fillable later, not required at signup time.
-- Safe: profiles_phone_check (`phone ~ '^\+60[0-9]{8,10}$'`) already passes
-- on NULL by ordinary SQL three-valued-logic CHECK semantics, and
-- profiles_phone_key is a plain UNIQUE index, under which multiple NULLs
-- are not considered equal -- confirmed via pg_indexes before writing this,
-- not assumed.
ALTER TABLE public.profiles ALTER COLUMN phone DROP NOT NULL;

-- 2. Create exactly one profiles row per new auth.users row.
--
-- SECURITY DEFINER is genuinely required: this trigger fires as part of the
-- INSERT into auth.users, which executes as supabase_auth_admin --
-- confirmed via information_schema.role_table_grants that role holds only
-- SELECT on public.profiles, never INSERT. search_path is pinned to ''
-- (empty), matching every other SECURITY DEFINER function already in this
-- schema (fn_quote_kirim, fn_delivery_transition, fn_check_serviceability,
-- ...), so every identifier below is fully schema-qualified and none of them
-- can be hijacked by a search_path substitution.
--
-- Deliberately does NOT touch public.user_roles, public.carriers, or
-- public.sellers: a new user gets no role row at all, and
-- public.custom_access_token_hook already treats "no role row" as the
-- CUSTOMER default on the client (COALESCE(to_jsonb(v_roles), '[]'::jsonb)
-- when the aggregate is over zero rows -- exercised directly by this
-- session's own AuthRoleResolutionTest suite, cases E/"no roles key"). A
-- CARRIER/SELLER identity is not derivable from anything a signing-up
-- client controls -- Supabase Auth sets no other claim from client input at
-- sign-up in this app -- so there is no privilege-escalation surface here
-- to guard against beyond simply never creating one.
CREATE OR REPLACE FUNCTION public.tg_create_profile_on_signup()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  INSERT INTO public.profiles (id, phone, status)
  VALUES (new.id, NULL, 'pending')
  ON CONFLICT (id) DO NOTHING;
  RETURN new;
END;
$function$;

-- A trigger-returning function cannot be invoked directly via SQL/RPC (only
-- the trigger machinery can call it) -- this REVOKE is defense-in-depth,
-- matching this schema's established explicit-grant convention, not the
-- only thing standing between a client and calling it.
REVOKE ALL ON FUNCTION public.tg_create_profile_on_signup() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER tg_auth_users_create_profile
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.tg_create_profile_on_signup();

-- 3. Backfill: any auth.users row that predates this trigger and still has
--    no profile (exactly one, confirmed live, as of writing this migration).
--    Idempotent: safe to re-run against a database where it has already
--    applied, and safe on a fresh database where the LEFT JOIN simply
--    matches zero rows.
INSERT INTO public.profiles (id, phone, status)
SELECT u.id, NULL, 'pending'
FROM auth.users u
LEFT JOIN public.profiles p ON p.id = u.id
WHERE p.id IS NULL
ON CONFLICT (id) DO NOTHING;
