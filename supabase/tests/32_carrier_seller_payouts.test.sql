-- ============================================================================
-- 0042_carrier_seller_payouts.sql regression tests.
--
-- The fixture carrier (rahman/_carrier) starts with no ledger balance, so
-- this file credits CARRIER_PAYABLE:<_carrier> by RM100 directly (the same
-- fn_post call a real settlement would make, per 01_constraints.test.sql's
-- own pattern) before exercising withdrawal against it.
-- ============================================================================
BEGIN;
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
  (SELECT count(*)::int FROM internal.bank_accounts WHERE owner_id = tests.uid('rahman')),
  1, 'the bank account row was actually created');
SELECT isnt(
  (SELECT account_no_enc FROM internal.bank_accounts WHERE owner_id = tests.uid('rahman')),
  '9876543210'::bytea,
  'the account number is stored encrypted, not as raw plaintext bytes');
SELECT is(
  (SELECT array_agg(bank_code)::text[] FROM public.rpc_my_bank_accounts()),
  ARRAY['MBB'], 'rpc_my_bank_accounts returns the caller''s own account');

-- ── rpc_request_withdrawal ───────────────────────────────────────────────────
SELECT throws_ok(
  $$SELECT public.rpc_request_withdrawal('carrier', gen_random_uuid(), 100)$$,
  NULL, NULL, 'a nonexistent bank account id is refused');
SELECT throws_ok(
  format($$SELECT public.rpc_request_withdrawal('carrier', %L, 999999)$$,
         (SELECT id FROM internal.bank_accounts WHERE owner_id = tests.uid('rahman'))),
  NULL, NULL, 'requesting more than the available balance is refused');

SELECT is(
  (public.rpc_request_withdrawal('carrier',
     (SELECT id FROM internal.bank_accounts WHERE owner_id = tests.uid('rahman')), 5000)
   )->>'status',
  'REQUESTED', 'a valid withdrawal request is accepted');

SELECT throws_ok(
  format($$SELECT public.rpc_request_withdrawal('carrier', %L, 6000)$$,
         (SELECT id FROM internal.bank_accounts WHERE owner_id = tests.uid('rahman'))),
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
  (public.rpc_admin_review_payout(
     (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
        AND status = 'REQUESTED' LIMIT 1), true)
   )->>'status',
  'UNDER_REVIEW', 'the reviewing admin moves the request to UNDER_REVIEW');

SELECT throws_ok(
  format($$SELECT public.rpc_admin_approve_payout(%L, true)$$,
         (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
            AND status = 'UNDER_REVIEW' LIMIT 1)),
  NULL, NULL,
  'THE ACTUAL POINT: the reviewing admin cannot also approve their own review');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin2');
SELECT is(
  (public.rpc_admin_approve_payout(
     (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
        AND status = 'UNDER_REVIEW' LIMIT 1), true)
   )->>'status',
  'APPROVED', 'a different admin can approve the same request');

SELECT is(
  (public.rpc_admin_mark_payout_paid(
     (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
        AND status = 'APPROVED' LIMIT 1), 'MANUAL-REF-1')
   )->>'status',
  'PAID', 'marking a payout paid succeeds and records a stub provider_ref');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_mark_payout_paid(%L)$$,
         (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
            AND status = 'PAID' LIMIT 1)),
  NULL, NULL, 'marking an already-PAID payout paid again is refused, not double-posted');
SELECT tests.clear_auth();

SELECT is(
  internal.fn_account_balance_sen('CARRIER_PAYABLE:'||(SELECT tests.uid('_carrier'))::text),
  5000::bigint,
  'the paid amount actually left the carrier''s ledger balance (10000 - 5000)');

-- ── a payout can also fail instead of pay, with no ledger effect ───────────
SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_request_withdrawal('carrier',
     (SELECT id FROM internal.bank_accounts WHERE owner_id = tests.uid('rahman')), 3000)
   )->>'status',
  'REQUESTED', 'rahman can request again against the remaining balance');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin2');
SELECT is(
  (public.rpc_admin_review_payout(
     (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
        AND status = 'REQUESTED' LIMIT 1), true)
   )->>'status',
  'UNDER_REVIEW', 'the second payout is reviewed by admin2 this time');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT is(
  (public.rpc_admin_approve_payout(
     (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
        AND status = 'UNDER_REVIEW' LIMIT 1), true)
   )->>'status',
  'APPROVED', 'admin approves what admin2 reviewed');
SELECT is(
  (public.rpc_admin_mark_payout_failed(
     (SELECT id FROM internal.payouts WHERE payee_id = tests.uid('_carrier')
        AND status = 'APPROVED' LIMIT 1), 'bank rejected the account details')
   )->>'status',
  'FAILED', 'a payout can be marked failed instead of paid');
SELECT tests.clear_auth();

SELECT is(
  internal.fn_account_balance_sen('CARRIER_PAYABLE:'||(SELECT tests.uid('_carrier'))::text),
  5000::bigint,
  'a FAILED payout never touched the ledger -- balance is unchanged');

SELECT ok(EXISTS (
  SELECT 1 FROM internal.payouts
   WHERE payee_id = tests.uid('_carrier') AND status = 'FAILED'
     AND failure_reason = 'bank rejected the account details'),
  'the failure reason is recorded');

SELECT * FROM finish();
ROLLBACK;
