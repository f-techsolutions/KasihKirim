-- ============================================================================
-- 0041_account_management.sql regression tests: rpc_admin_set_account_status
-- and the custom_access_token_hook enforcement it depends on.
--
-- The enforcement half is the actual point of this migration -- without it,
-- setting profiles.status is cosmetic (confirmed by grep: nothing else in
-- the schema ever read it). Every assertion below that calls the hook
-- directly is exercising the exact function the real Supabase Auth Hook
-- invokes at token-mint time (same pattern 11_profile_on_signup.test.sql
-- already uses for the pre-existing parts of this hook) -- which is also
-- why every such call is made only after tests.clear_auth(): 0003 REVOKEs
-- EXECUTE on this function from authenticated/anon/PUBLIC and grants it only
-- to supabase_auth_admin, so calling it while still tests.authenticate_as()
-- would fail on a permission error rather than exercise the hook's own logic.
-- ============================================================================
BEGIN;
SELECT plan(15);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- ── authorization ────────────────────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_set_account_status(%L,'suspended')$$, tests.uid('rahman')),
  NULL, NULL, 'a non-admin caller cannot call rpc_admin_set_account_status at all');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');

SELECT throws_ok(
  format($$SELECT public.rpc_admin_set_account_status(%L,'pending')$$, tests.uid('aisyah')),
  NULL, NULL, 'setting status to pending (a pre-activation state) is refused');
SELECT throws_ok(
  $$SELECT public.rpc_admin_set_account_status(gen_random_uuid(),'suspended')$$,
  NULL, NULL, 'a nonexistent user id is refused');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_set_account_status(%L,'suspended')$$, tests.uid('admin')),
  NULL, NULL, 'an admin cannot act on their own account');

-- ── suspension: recorded and (this is the actual point) enforced ───────────
SELECT is((public.rpc_admin_set_account_status(tests.uid('aisyah'),'suspended','reported by another user'))->>'status',
  'suspended', 'admin can suspend an account');
SELECT is((SELECT status::text FROM public.profiles WHERE id = tests.uid('aisyah')),
  'suspended', 'the suspension is actually persisted');
SELECT is((SELECT suspended_reason FROM public.profiles WHERE id = tests.uid('aisyah')),
  'reported by another user', 'the reason is recorded');
SELECT tests.clear_auth();

SELECT throws_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         tests.uid('aisyah'), tests.uid('aisyah')),
  NULL, NULL,
  'THE ACTUAL POINT: the token-mint hook now refuses a suspended account, not just a status label');

-- ── restoring to active undoes both the record and the block ───────────────
SELECT tests.authenticate_as('admin');
SELECT is((public.rpc_admin_set_account_status(tests.uid('aisyah'),'active'))->>'status',
  'active', 'admin can restore a suspended account');
SELECT is((SELECT suspended_reason FROM public.profiles WHERE id = tests.uid('aisyah')),
  NULL, 'restoring to active clears the old suspension reason');
SELECT tests.clear_auth();
SELECT lives_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         tests.uid('aisyah'), tests.uid('aisyah')),
  'restoring to active lets the hook mint a token again');

-- ── banning is enforced the same way as suspension ──────────────────────────
SELECT tests.authenticate_as('admin');
SELECT is((public.rpc_admin_set_account_status(tests.uid('rahman'),'banned','fraud'))->>'status',
  'banned', 'admin can ban an account');
SELECT tests.clear_auth();
SELECT throws_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         tests.uid('rahman'), tests.uid('rahman')),
  NULL, NULL, 'a banned account is refused a token exactly like a suspended one');

-- A banned carrier's OWN existing sessions aside, nothing about their
-- carrier_id resolution changes server-side -- this migration only gates
-- token minting, not carriers/sellers RLS, which is unaffected.
SELECT ok(EXISTS (SELECT 1 FROM public.carriers WHERE user_id = tests.uid('rahman') AND status='APPROVED'),
  'banning an account does not itself touch carrier/seller role rows');

-- ── a user with no profile row at all is unaffected (mid-signup case) ──────
SELECT lives_ok(
  format($$SELECT public.custom_access_token_hook(
            jsonb_build_object('user_id',%L,'claims',jsonb_build_object('sub',%L)))$$,
         gen_random_uuid(), gen_random_uuid()),
  'a user with no profiles row yet falls through to normal minting, not a false block');

SELECT tests.clear_auth();
SELECT * FROM finish();
ROLLBACK;
