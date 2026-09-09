-- ============================================================================
-- Delivery proof gating (0014). ref.delivery_transition_rules already marked
-- CONFIRM_PICKUP/CONFIRM_DELIVERY/CONFIRM_RETURN as requires_proof; nothing
-- ever checked it. These assert the check now actually blocks and unblocks.
-- ============================================================================
BEGIN;
SELECT plan(10);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

DO $$
DECLARE v_d UUID;
BEGIN
  INSERT INTO public.deliveries (kirim_id,carrier_id,status)
  VALUES (tests.uid('_kirim'), tests.uid('_carrier'), 'AWAITING_PICKUP')
  RETURNING id INTO v_d;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_delivery2',v_d)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- ── The gate: no proof on record, transition is refused ────────────────────
SELECT throws_ok(
  format($$SELECT internal.fn_delivery_transition(%L,'CONFIRM_PICKUP',%L,'carrier')$$,
         tests.uid('_delivery2'), tests.uid('rahman')),
  NULL, NULL, 'CONFIRM_PICKUP is refused with no pickup proof on record');

-- ── Only the assigned carrier may submit one ────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_submit_proof(%L,'pickup','PHOTO',now(),'photo.jpg')$$,
         tests.uid('_delivery2')),
  NULL, NULL, 'a user who is not the assigned carrier cannot submit a proof');

-- ── A bare photo is WEAK; a mock-location photo is SUSPECT; a QR is STRONG ──
SELECT tests.authenticate_as('rahman');

SELECT throws_ok(
  format($$SELECT public.rpc_submit_proof(%L,'pickup','PHOTO',now())$$,
         tests.uid('_delivery2')),
  NULL, NULL, 'PHOTO method without a photo_path is rejected');

DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_submit_proof(
    tests.uid('_delivery2'), 'pickup', 'PHOTO', now(), 'pickup.jpg');
  INSERT INTO tests.handles (handle,user_id) VALUES ('_proof_pickup',(v_result->>'proof_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT quality::text FROM public.proofs WHERE id=tests.uid('_proof_pickup')),
  'WEAK', 'a bare photo, no mock-location flag, is scored WEAK');

DO $$
BEGIN
  PERFORM public.rpc_submit_proof(
    tests.uid('_delivery2'), 'pickup', 'PHOTO', now(), 'pickup2.jpg',
    p_is_mock_location := true);
END $$;

SELECT is((SELECT quality::text FROM public.proofs
           WHERE delivery_id=tests.uid('_delivery2') AND leg='pickup'),
  'SUSPECT', 'resubmitting with is_mock_location=true escalates to SUSPECT and replaces the row');

DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_submit_proof(
    tests.uid('_delivery2'), 'dropoff', 'QR', now());
END $$;

SELECT is((SELECT quality::text FROM public.proofs
           WHERE delivery_id=tests.uid('_delivery2') AND leg='dropoff'),
  'STRONG', 'a QR handshake is scored STRONG with no photo required');

-- ── Now the pickup leg has a proof: CONFIRM_PICKUP succeeds. Schema
--    `internal` has no grant to `authenticated` (0000) -- calling
--    internal.fn_delivery_transition directly, as every other test in this
--    suite does, needs postgres context, not an authenticated session. ────
SELECT tests.clear_auth();
SELECT lives_ok(
  format($$SELECT internal.fn_delivery_transition(%L,'CONFIRM_PICKUP',%L,'carrier')$$,
         tests.uid('_delivery2'), tests.uid('rahman')),
  'CONFIRM_PICKUP succeeds once a pickup-leg proof exists');

SELECT is((SELECT pickup_proof_quality::text FROM public.deliveries WHERE id=tests.uid('_delivery2')),
  'SUSPECT', 'the delivery row is denormalised with the pickup proof quality on transition');

-- ── Leg-specific: the dropoff-leg proof submitted above is what lets
--    CONFIRM_DELIVERY through once the delivery reaches OUT_FOR_DELIVERY.
--    Direct UPDATE, not a real transition -- deliveries.status writes are
--    revoked from `authenticated` (0001), so this needs postgres, the same
--    superuser-as-test-scaffolding shortcut 07_compliance.test.sql uses. ───
SELECT tests.clear_auth();
UPDATE public.deliveries SET status='OUT_FOR_DELIVERY' WHERE id=tests.uid('_delivery2');

SELECT lives_ok(
  format($$SELECT internal.fn_delivery_transition(%L,'CONFIRM_DELIVERY',%L,'carrier')$$,
         tests.uid('_delivery2'), tests.uid('rahman')),
  'CONFIRM_DELIVERY succeeds: the dropoff-leg proof submitted earlier already covers it');

SELECT is((SELECT dropoff_proof_quality::text FROM public.deliveries WHERE id=tests.uid('_delivery2')),
  'STRONG', 'the delivery row is denormalised with the dropoff proof quality on transition');

SELECT * FROM finish();
ROLLBACK;
