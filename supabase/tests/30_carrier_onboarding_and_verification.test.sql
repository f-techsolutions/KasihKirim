-- ============================================================================
-- 0040_carrier_onboarding_and_verification.sql regression tests:
-- rpc_apply_carrier and rpc_admin_set_carrier_status. Mirrors
-- 13_seller_onboarding.test.sql's own coverage of rpc_apply_seller, plus the
-- role-grant/revoke invariant rpc_admin_set_seller_status has never had its
-- own dedicated test for -- exercised here since this is a byte-for-byte
-- copy of that RPC's shape.
-- ============================================================================
BEGIN;
SELECT plan(17);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p40_applicant',  '+60128884001', ARRAY['customer']);
SELECT tests.create_user('p40_applicant2', '+60128884002', ARRAY['customer']);

-- ── rpc_apply_carrier ────────────────────────────────────────────────────────
SELECT tests.authenticate_as('p40_applicant');
DO $$
DECLARE v_result JSONB; v_kepayan UUID;
BEGIN
  SELECT id INTO v_kepayan FROM public.communities WHERE name = 'Kg Kepayan Baru';
  v_result := public.rpc_apply_carrier(v_kepayan);
  INSERT INTO tests.handles (handle, user_id) VALUES ('_p40_carrier', (v_result->>'carrier_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

SELECT is((SELECT status::text FROM public.carriers WHERE id = tests.uid('_p40_carrier')),
  'NOT_STARTED', 'a new carrier application starts at NOT_STARTED');
SELECT is((SELECT user_id FROM public.carriers WHERE id = tests.uid('_p40_carrier')),
  tests.uid('p40_applicant'), 'the application is owned by the applicant');

SELECT throws_ok(
  format($$SELECT public.rpc_apply_carrier(%L)$$,
         (SELECT id FROM public.communities WHERE name='Kg Kepayan Baru')),
  NULL, NULL, 'a second application from the same user is rejected');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('p40_applicant2');
SELECT throws_ok(
  $$SELECT public.rpc_apply_carrier(gen_random_uuid())$$,
  NULL, NULL, 'applying with a nonexistent community is rejected');
SELECT tests.clear_auth();

-- ── rpc_admin_set_carrier_status: authorization + validation ──────────────────
SELECT tests.authenticate_as('p40_applicant');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_set_carrier_status(%L, 'APPROVED')$$, tests.uid('_p40_carrier')),
  NULL, NULL, 'a non-admin caller cannot call rpc_admin_set_carrier_status at all');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_set_carrier_status(%L, 'NOT_A_REAL_STATUS')$$, tests.uid('_p40_carrier')),
  NULL, NULL, 'an invalid status value is refused');
SELECT throws_ok(
  $$SELECT public.rpc_admin_set_carrier_status(gen_random_uuid(), 'APPROVED')$$,
  NULL, NULL, 'a nonexistent carrier id is refused');

-- ── approval grants the role and stamps verified_at ────────────────────────────
DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_admin_set_carrier_status(tests.uid('_p40_carrier'), 'APPROVED', 'looks good');
  PERFORM set_config('tests.p40_role_active', v_result->>'role_active', false);
END $$;

SELECT is((SELECT status::text FROM public.carriers WHERE id = tests.uid('_p40_carrier')),
  'APPROVED', 'admin approval sets the carrier to APPROVED');
SELECT is((SELECT review_note FROM public.carriers WHERE id = tests.uid('_p40_carrier')),
  'looks good', 'the reviewer note is recorded');
SELECT ok((SELECT verified_at FROM public.carriers WHERE id = tests.uid('_p40_carrier')) IS NOT NULL,
  'verified_at is stamped on approval');
SELECT is(current_setting('tests.p40_role_active'), 'true',
  'the RPC reports role_active=true on approval');
SELECT ok(EXISTS (SELECT 1 FROM public.user_roles
                   WHERE user_id = tests.uid('p40_applicant') AND role = 'carrier'
                     AND revoked_at IS NULL),
  'the carrier role is granted, live, in the same transaction');

-- ── a second approval call is idempotent, not a duplicate grant ───────────────
SELECT public.rpc_admin_set_carrier_status(tests.uid('_p40_carrier'), 'APPROVED');
SELECT is((SELECT count(*)::int FROM public.user_roles
            WHERE user_id = tests.uid('p40_applicant') AND role = 'carrier'),
  1, 'a second approval does not create a duplicate role row');

-- ── suspension revokes the role without deleting the carrier row ──────────────
SELECT public.rpc_admin_set_carrier_status(tests.uid('_p40_carrier'), 'SUSPENDED', 'float exposure review');
SELECT is((SELECT status::text FROM public.carriers WHERE id = tests.uid('_p40_carrier')),
  'SUSPENDED', 'admin can suspend an approved carrier');
SELECT ok(EXISTS (SELECT 1 FROM public.user_roles
                   WHERE user_id = tests.uid('p40_applicant') AND role = 'carrier'
                     AND revoked_at IS NOT NULL),
  'suspension revokes the carrier role');

-- ── rejecting a different applicant never grants a role at all ────────────────
SELECT tests.authenticate_as('p40_applicant2');
DO $$
DECLARE v_result JSONB; v_kk UUID;
BEGIN
  SELECT id INTO v_kk FROM public.communities WHERE name = 'Kg Kepayan Baru';
  v_result := public.rpc_apply_carrier(v_kk);
  INSERT INTO tests.handles (handle, user_id) VALUES ('_p40_carrier2', (v_result->>'carrier_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_carrier_status(tests.uid('_p40_carrier2'), 'REJECTED', 'incomplete documents');
SELECT is((SELECT status::text FROM public.carriers WHERE id = tests.uid('_p40_carrier2')),
  'REJECTED', 'admin can reject an application');
SELECT ok(NOT EXISTS (SELECT 1 FROM public.user_roles
                       WHERE user_id = tests.uid('p40_applicant2') AND role = 'carrier'),
  'a rejected applicant is never granted the carrier role');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
