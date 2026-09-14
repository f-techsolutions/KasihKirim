-- ============================================================================
-- 0042_carrier_seller_payouts.sql regression tests.
--
-- The fixture carrier (rahman/_carrier) starts with no ledger balance, so
-- this file credits CARRIER_PAYABLE:<_carrier> by RM100 directly (the same
-- fn_post call a real settlement would make, per 01_constraints.test.sql's
-- own pattern) before exercising withdrawal against it.
--
-- Schema internal has zero grant to `authenticated` (0000_prelude.sql), so
-- once a test authenticates as a real user it cannot query
-- internal.bank_accounts/internal.payouts directly to find an id to act on
-- next -- every id this file needs while authenticated is instead read back
-- through the same public RPCs a real client would use (rpc_my_bank_accounts,
-- rpc_my_payouts, rpc_admin_list_payouts) and stashed in tests.handles, the
-- exact use case 00_helpers.sql's own "TEST-ONLY GRANTS" comment documents.
-- Raw internal.* reads only ever happen after tests.clear_auth(), running as
-- postgres, which schema grants never restrict.
--
-- rpc_add_bank_account reads its encryption key from the Postgres GUC
-- app.settings.bank_account_enc_key, which no migration sets (a real
-- project configures it once via the Supabase dashboard). SET LOCAL gives
-- this transaction its own value without needing the elevated privilege
-- ALTER DATABASE would (confirmed live: ALTER DATABASE ... SET on this
-- parameter came back "permission denied to set parameter" for the role
-- CI's psql connects as, while SET LOCAL on the same parameter, in the
-- same transaction, does not -- the two have different privilege
-- requirements even for the same custom GUC).
-- ============================================================================
BEGIN;
SET LOCAL app.settings.bank_account_enc_key = 'pgtap-local-test-key-do-not-use-in-production';
SELECT plan(25);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();
SELECT tests.create_user('admin2', '+60128880099', ARRAY['admin_ops']);

DO $seed$
DECLARE v_txn UUID;
BEGIN
  INSERT INTO internal.ledger_transactions (kind, reference_type, reference_id, idempotency_key)
  VALUES ('TEST_CREDIT', 'test', gen_random_uuid(), 'test-credit-'||gen_random_uuid()::text)
  RETURNING id INTO v_txn;
  PERFORM internal.fn_post(v_txn, 'ESCROW_HELD_DELIVERY', 'DEBIT', 10000);
  PERFORM internal.fn_post(v_txn, 'CARRIER_PAYABLE:'||(SELECT tests.uid('_carrier'))::text, 'CREDIT', 10000);
END $seed$;

-- ── rpc_add_bank_account ─────────────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  $$SELECT public.rpc_add_bank_account('MBB','1234567890','Aisyah')$$,
  NULL, NULL, 'a plain customer with no carrier/seller id cannot add a bank account');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_add_bank_account('MBB','12','Rahman')$$,
  NULL, NULL, 'an account number too short to yield a last-4 is refused');

SELECT is(
  (public.rpc_add_bank_account('MBB','9876543210','Rahman bin Ahmad'))->>'account_no_last4',
  '3210', 'adding a bank account returns only the last 4 digits');
SELECT is(
  (SELECT count(*)::int FROM public.rpc_my_bank_accounts()),
  1, 'the bank account row was actually created');
SELECT is(
  (SELECT array_agg(bank_code)::text[] FROM public.rpc_my_bank_accounts()),
  ARRAY['MBB'], 'rpc_my_bank_accounts returns the caller''s own account');

-- Stash the new bank account's own id (read back through the RPC, not the
-- table) so later steps -- still authenticated as a real user -- can refer
-- to it without ever touching internal.bank_accounts directly.
INSERT INTO tests.handles (handle, user_id)
SELECT '_bank', id FROM public.rpc_my_bank_accounts() LIMIT 1
ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;

-- ── rpc_request_withdrawal ───────────────────────────────────────────────────
SELECT throws_ok(
  $$SELECT public.rpc_request_withdrawal('carrier', gen_random_uuid(), 100)$$,
  NULL, NULL, 'a nonexistent bank account id is refused');
SELECT throws_ok(
  format($$SELECT public.rpc_request_withdrawal('carrier', %L, 999999)$$, tests.uid('_bank')),
  NULL, NULL, 'requesting more than the available balance is refused');

SELECT is(
  (public.rpc_request_withdrawal('carrier', tests.uid('_bank'), 5000))->>'status',
  'REQUESTED', 'a valid withdrawal request is accepted');

INSERT INTO tests.handles (handle, user_id)
SELECT '_payout1', id FROM public.rpc_my_payouts() WHERE status = 'REQUESTED' LIMIT 1
ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;

SELECT throws_ok(
  format($$SELECT public.rpc_request_withdrawal('carrier', %L, 6000)$$, tests.uid('_bank')),
  NULL, NULL,
  'a second request is refused once it and the first REQUESTED one would exceed the balance');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  $$SELECT public.rpc_request_withdrawal('carrier', gen_random_uuid(), 100)$$,
  NULL, NULL, 'a user with no carrier_id cannot request a carrier withdrawal');
SELECT tests.clear_auth();

-- ── admin maker-checker ──────────────────────────────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_admin_list_payouts()$$,
  NULL, NULL, 'a non-admin cannot list payouts');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT ok(
  (SELECT count(*)::int FROM public.rpc_admin_list_payouts()) >= 1,
  'the admin queue shows the pending payout');

SELECT is(
  (public.rpc_admin_review_payout(tests.uid('_payout1'), true))->>'status',
  'UNDER_REVIEW', 'the reviewing admin moves the request to UNDER_REVIEW');

SELECT throws_ok(
  format($$SELECT public.rpc_admin_approve_payout(%L, true)$$, tests.uid('_payout1')),
  NULL, NULL,
  'THE ACTUAL POINT: the reviewing admin cannot also approve their own review');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin2');
SELECT is(
  (public.rpc_admin_approve_payout(tests.uid('_payout1'), true))->>'status',
  'APPROVED', 'a different admin can approve the same request');

SELECT is(
  (public.rpc_admin_mark_payout_paid(tests.uid('_payout1'), 'MANUAL-REF-1'))->>'status',
  'PAID', 'marking a payout paid succeeds and records a stub provider_ref');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_mark_payout_paid(%L)$$, tests.uid('_payout1')),
  NULL, NULL, 'marking an already-PAID payout paid again is refused, not double-posted');
SELECT tests.clear_auth();

SELECT is(
  internal.fn_account_balance_sen('CARRIER_PAYABLE:'||(SELECT tests.uid('_carrier'))::text),
  5000::bigint,
  'the paid amount actually left the carrier''s ledger balance (10000 - 5000)');

-- ── a payout can also fail instead of pay, with no ledger effect ───────────
SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_request_withdrawal('carrier', tests.uid('_bank'), 3000))->>'status',
  'REQUESTED', 'rahman can request again against the remaining balance');

INSERT INTO tests.handles (handle, user_id)
SELECT '_payout2', id FROM public.rpc_my_payouts() WHERE status = 'REQUESTED' LIMIT 1
ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin2');
SELECT is(
  (public.rpc_admin_review_payout(tests.uid('_payout2'), true))->>'status',
  'UNDER_REVIEW', 'the second payout is reviewed by admin2 this time');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT is(
  (public.rpc_admin_approve_payout(tests.uid('_payout2'), true))->>'status',
  'APPROVED', 'admin approves what admin2 reviewed');
SELECT is(
  (public.rpc_admin_mark_payout_failed(tests.uid('_payout2'), 'bank rejected the account details'))->>'status',
  'FAILED', 'a payout can be marked failed instead of paid');
SELECT tests.clear_auth();

SELECT is(
  internal.fn_account_balance_sen('CARRIER_PAYABLE:'||(SELECT tests.uid('_carrier'))::text),
  5000::bigint,
  'a FAILED payout never touched the ledger -- balance is unchanged');

SELECT ok(EXISTS (
  SELECT 1 FROM internal.payouts
   WHERE id = tests.uid('_payout2') AND status = 'FAILED'
     AND failure_reason = 'bank rejected the account details'),
  'the failure reason is recorded');

-- Only checked here, as postgres: account_no_enc is never readable through
-- any RPC this file has authenticated as a client to call.
SELECT isnt(
  (SELECT account_no_enc FROM internal.bank_accounts WHERE id = tests.uid('_bank')),
  '9876543210'::bytea,
  'the account number is stored encrypted, not as raw plaintext bytes');

SELECT * FROM finish();
ROLLBACK;
