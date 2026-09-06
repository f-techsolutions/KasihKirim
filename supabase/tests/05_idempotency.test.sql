-- ============================================================================
-- Exactly-once. The property that makes offline work safe.
-- ============================================================================
BEGIN;
SELECT plan(5);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

DO $$
DECLARE v_d UUID;
BEGIN
  INSERT INTO public.deliveries (kirim_id,carrier_id,status)
  VALUES (tests.uid('_kirim'), tests.uid('_carrier'),'MATCHED')
  RETURNING id INTO v_d;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_delivery',v_d)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- A handover confirmed in a valley with no signal, retried 11 times over three
-- days as the phone drifts in and out of coverage. All 11 carry the key that
-- was born when the user tapped.
DO $$
DECLARE i INT;
BEGIN
  FOR i IN 1..11 LOOP
    PERFORM internal.fn_delivery_transition(
      tests.uid('_delivery'),'START_PROCUREMENT',tests.uid('rahman'),'carrier',
      'offline-key-fixed');
  END LOOP;
END $$;

SELECT is((SELECT count(*) FROM public.delivery_events
           WHERE delivery_id=tests.uid('_delivery') AND event='START_PROCUREMENT'),
  1::bigint, '11 replays of one idempotency key produce exactly one event');

SELECT is((SELECT status FROM public.deliveries WHERE id=tests.uid('_delivery')),
  'PROCURING'::ref.kirim_status, 'state advanced exactly one step');

-- Webhook dedupe is a UNIQUE constraint, not application logic.
INSERT INTO internal.webhook_events (provider,provider_event_id,signature_valid,payload)
VALUES ('billplz','evt_1',true,'{"status":"paid"}');

SELECT throws_ok(
  $$INSERT INTO internal.webhook_events (provider,provider_event_id,signature_valid,payload)
    VALUES ('billplz','evt_1',true,'{"status":"paid"}')$$,
  '23505', NULL, 'duplicate webhook event rejected by unique constraint');

-- Ledger transactions are keyed too.
INSERT INTO internal.ledger_transactions (kind,reference_type,reference_id,idempotency_key)
VALUES ('TEST','x',gen_random_uuid(),'dup-key');

SELECT throws_ok(
  $$INSERT INTO internal.ledger_transactions
      (kind,reference_type,reference_id,idempotency_key)
    VALUES ('TEST','x',gen_random_uuid(),'dup-key')$$,
  '23505', NULL, 'duplicate ledger transaction key rejected');

-- QR nonces: first use wins.
INSERT INTO internal.handover_nonces (nonce,delivery_id,leg,consumed_by)
VALUES ('nonce-abc', tests.uid('_delivery'),'dropoff', tests.uid('rahman'));

SELECT throws_ok(
  format($$INSERT INTO internal.handover_nonces (nonce,delivery_id,leg,consumed_by)
           VALUES ('nonce-abc',%L,'dropoff',%L)$$,
         tests.uid('_delivery'), tests.uid('rahman')),
  '23505', NULL, 'replayed QR nonce rejected — screenshot attack fails');

SELECT * FROM finish();
ROLLBACK;
