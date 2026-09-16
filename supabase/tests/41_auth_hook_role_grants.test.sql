-- ============================================================================
-- 0051_auth_hook_ref_schema_grant.sql regression test.
--
-- Production incident this closes: 0041_account_management.sql added
-- `v_status ref.account_status;` to public.custom_access_token_hook's own
-- DECLARE block, the first time the hook ever referenced schema ref.
-- supabase_auth_admin -- the role GoTrue actually invokes the hook as --
-- was only ever granted USAGE on schema public (0003_functions_rls.sql),
-- never on schema ref. Resolving that DECLARE's type needs schema-level
-- USAGE regardless of any table grant, so every real sign-in and token
-- refresh started failing closed with "permission denied for schema ref"
-- (SQLSTATE 42501) the moment 0041 shipped.
--
-- Every existing custom_access_token_hook assertion (11_profile_on_signup,
-- 31_account_management) calls the hook only after tests.clear_auth(),
-- which leaves the session as postgres. That role bypasses schema ACLs
-- entirely -- not as a Postgres superuser (it isn't marked SUPERUSER in
-- Supabase's own role model, confirmed the hard way: SET ROLE
-- supabase_auth_admin from postgres itself fails with the exact same
-- "permission denied" class of error this migration fixes, since
-- supabase_auth_admin is deliberately not grantable to postgres, one of
-- the security boundaries Supabase's own service roles rely on) but via
-- whatever broader grants postgres separately holds. Either way, none of
-- the existing assertions could ever have caught a missing
-- supabase_auth_admin grant, so the incident shipped straight through a
-- green test suite.
--
-- Since supabase_auth_admin can't be impersonated even from this harness,
-- this asserts its privileges directly against the catalog instead of
-- trying to execute as it -- has_schema_privilege/has_function_privilege/
-- has_table_privilege read exactly what GoTrue's own connection would be
-- limited to, without requiring a SET ROLE this role model forbids.
-- ============================================================================
BEGIN;
SELECT plan(4);
SELECT tests.clear_auth();

-- ── the actual regression ────────────────────────────────────────────────
SELECT ok(
  has_schema_privilege('supabase_auth_admin', 'ref', 'USAGE'),
  'supabase_auth_admin holds USAGE on schema ref -- the grant 0051 adds, and the exact one 0041 silently needed');

-- ── baseline grants the hook has relied on since 0003, unaffected by this
-- incident -- included so a future regression here fails in the same file
-- rather than being mistaken for this one ─────────────────────────────────
SELECT ok(
  has_schema_privilege('supabase_auth_admin', 'public', 'USAGE'),
  'supabase_auth_admin holds USAGE on schema public');
SELECT ok(
  has_function_privilege('supabase_auth_admin', 'public.custom_access_token_hook(jsonb)', 'EXECUTE'),
  'supabase_auth_admin can execute the hook itself');
SELECT ok(
  has_table_privilege('supabase_auth_admin', 'public.profiles', 'SELECT'),
  'supabase_auth_admin can read public.profiles, where the hook resolves account_status');

SELECT * FROM finish();
ROLLBACK;
