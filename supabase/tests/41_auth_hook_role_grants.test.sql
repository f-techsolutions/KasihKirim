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
-- which leaves the session as postgres -- a superuser that bypasses schema
-- ACLs entirely, same as it bypasses the EXECUTE grant 0003's own comment
-- warns about. None of them could have caught a missing supabase_auth_admin
-- grant; the incident shipped straight through a green test suite. This
-- file calls the hook AS supabase_auth_admin specifically, the one role
-- whose privileges actually matter here, the same way GoTrue really does.
-- ============================================================================
BEGIN;
SELECT plan(5);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- ── the actual incident: resolving ref.account_status as supabase_auth_admin ──
SELECT set_config('role', 'supabase_auth_admin', true);

SELECT lives_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         tests.uid('rahman'), tests.uid('rahman')),
  'supabase_auth_admin can execute the hook for an existing user without a schema-ref permission error');

SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', tests.uid('rahman'),
       'claims', jsonb_build_object('sub', tests.uid('rahman')))
   )->'claims'->'app_metadata'->>'carrier_id'),
  (SELECT id::text FROM public.carriers WHERE user_id = tests.uid('rahman')),
  'as supabase_auth_admin, the hook still resolves a real carrier_id end to end');

-- A user with no profiles row yet (mid-signup) still falls through cleanly
-- as the real caller, not just as postgres.
SELECT lives_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         gen_random_uuid(), gen_random_uuid()),
  'as supabase_auth_admin, a user with no profiles row yet still falls through to normal minting');

SELECT set_config('role', 'postgres', true);

-- ── the enforcement path (0041) also runs as the real caller ────────────────
SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_account_status(tests.uid('aisyah'), 'suspended', 'test');
SELECT tests.clear_auth();

SELECT set_config('role', 'supabase_auth_admin', true);
SELECT throws_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         tests.uid('aisyah'), tests.uid('aisyah')),
  NULL, NULL,
  'as supabase_auth_admin, a suspended account is still refused a token, not silently 500''d differently');
SELECT set_config('role', 'postgres', true);

-- ── the grant itself, so this test fails loudly if 0051 is ever reverted ───
SELECT ok(
  has_schema_privilege('supabase_auth_admin', 'ref', 'USAGE'),
  'supabase_auth_admin holds USAGE on schema ref');

SELECT * FROM finish();
ROLLBACK;
