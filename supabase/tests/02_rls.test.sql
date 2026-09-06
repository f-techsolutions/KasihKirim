-- ============================================================================
-- The RLS matrix. The most important suite in the repo.
--
-- Deny cases are the point. A suite that only asserts what users CAN do will
-- pass happily against a policy that grants everything.
-- ============================================================================
BEGIN;
SELECT plan(20);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();

-- ── Carrier on the board: sees the request, NOT the contact details ────────
SELECT tests.authenticate_as('rahman');

SELECT is((SELECT count(*) FROM public.kirim_requests WHERE status='POSTED'),
  1::bigint, 'carrier sees posted board items');

SELECT is((SELECT count(*) FROM public.addresses), 0::bigint,
  'carrier CANNOT read the requester address before matching');

SELECT is((SELECT count(*) FROM public.profiles WHERE id <> tests.uid('rahman')),
  0::bigint, 'carrier cannot enumerate other profiles');

-- This is the difference between a marketplace and a scraped contact list,
-- and it is the exact failure of the WhatsApp-status economy we replace.
SELECT is((SELECT count(*) FROM public.v_public_profiles),
  4::bigint, 'public projection exposes name + rating only');

-- ── Deliveries are server-owned (BR-904) ───────────────────────────────────
SELECT throws_ok(
  $$INSERT INTO public.deliveries (kirim_id,carrier_id,status)
    VALUES (tests.uid('_kirim'), tests.uid('_carrier'),'DELIVERED')$$,
  '42501', NULL, 'carrier cannot insert a delivery directly');

SELECT throws_ok(
  $$UPDATE public.deliveries SET status='COMPLETED'$$,
  '42501', NULL, 'carrier cannot update delivery status directly');

-- ── Handover codes are readable by nobody ──────────────────────────────────
SELECT throws_ok(
  $$SELECT * FROM public.handover_codes$$,
  '42501', NULL, 'handover codes unreadable even by the assigned carrier');

-- ── internal schema is unreachable from any JWT ────────────────────────────
SELECT throws_ok($$SELECT * FROM internal.ledger_entries$$,
  '42501', NULL, 'ledger unreachable');
SELECT throws_ok($$SELECT * FROM internal.payments$$,
  '42501', NULL, 'payments unreachable');
SELECT throws_ok($$SELECT * FROM internal.payouts$$,
  '42501', NULL, 'payouts unreachable');
SELECT throws_ok($$SELECT * FROM audit.audit_logs$$,
  '42501', NULL, 'audit log unreachable');

-- ── Requester scope ────────────────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');

SELECT is((SELECT count(*) FROM public.kirim_requests), 1::bigint,
  'requester sees her own kirim');
SELECT is((SELECT count(*) FROM public.addresses), 1::bigint,
  'requester sees her own address');

SELECT is(
  (
    WITH changed AS (
      UPDATE public.kirim_requests
      SET budget_cap_sen = 1
      WHERE reference_code = 'KK-TEST01'
      RETURNING id
    )
    SELECT count(*) FROM changed
  ),
  0::bigint,
  'requester cannot edit a POSTED kirim (drafts only)'
);

-- Protected columns: an UPDATE policy alone cannot stop self-rating.
UPDATE public.profiles SET rating_avg = 5.0, status = 'active'
  WHERE id = tests.uid('aisyah');
SELECT is((SELECT rating_avg FROM public.profiles WHERE id=tests.uid('aisyah')),
  0.00::numeric, 'trigger silently reverts a self-awarded rating');

-- ── A stranger sees nothing ────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');

SELECT is((SELECT count(*) FROM public.addresses), 0::bigint,
  'stranger sees no addresses');
SELECT is((SELECT count(*) FROM public.kirim_requests), 0::bigint,
  'stranger without the carrier role sees no board items');
SELECT is((SELECT count(*) FROM public.deliveries), 0::bigint,
  'stranger sees no deliveries');

-- ── Admin ──────────────────────────────────────────────────────────────────
SELECT tests.authenticate_as('admin');
SELECT ok((SELECT count(*) FROM public.kirim_requests) >= 1,
  'admin_ops can inspect kirim requests');
SELECT throws_ok($$SELECT * FROM internal.ledger_entries$$,
  '42501', NULL, 'even admin_ops cannot reach the ledger through PostgREST');

SELECT * FROM finish();
ROLLBACK;
