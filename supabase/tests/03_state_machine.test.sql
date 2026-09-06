-- ============================================================================
-- State machine. Generated from ref.delivery_transition_rules, so the test set
-- expands automatically whenever a rule is added.
-- ============================================================================
BEGIN;
SELECT plan(9);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- Graph sanity ---------------------------------------------------------------
SELECT ok((SELECT count(*) FROM ref.delivery_transition_rules) > 15,
  'transition rules are seeded');

-- No dead ends: a non-terminal state with no way out strands a real parcel
-- in a real village.
SELECT is(
  (SELECT count(*) FROM (
     SELECT DISTINCT to_status FROM ref.delivery_transition_rules
     WHERE to_status NOT IN ('COMPLETED','CANCELLED','EXPIRED','RETURNED',
                             'REFUNDED','PROCUREMENT_FAILED','DISPUTED')
       AND to_status NOT IN (SELECT from_status FROM ref.delivery_transition_rules)
   ) x), 0::bigint,
  'every non-terminal state has at least one outgoing transition');

-- Terminal states must be genuinely terminal.
SELECT is(
  (SELECT count(*) FROM ref.delivery_transition_rules
   WHERE from_status IN ('COMPLETED','CANCELLED','REFUNDED','RETURNED')), 0::bigint,
  'terminal states have no outgoing transitions');

-- BELI-only events must not apply to HANTAR.
SELECT is(
  (SELECT count(*) FROM ref.delivery_transition_rules
   WHERE event='RECORD_PURCHASE' AND 'HANTAR' = ANY(applies_to_types)), 0::bigint,
  'RECORD_PURCHASE does not apply to HANTAR');

-- Both handover legs require proof.
SELECT is(
  (SELECT count(*) FROM ref.delivery_transition_rules
   WHERE event IN ('CONFIRM_PICKUP','CONFIRM_DELIVERY') AND NOT requires_proof),
  0::bigint, 'both handover events require proof');

-- BR-907: only the recipient side closes escrow.
SELECT ok(
  (SELECT 'customer' = ANY(allowed_roles) FROM ref.delivery_transition_rules
   WHERE event='CONFIRM_RECEIPT'),
  'the recipient can confirm receipt');
SELECT ok(
  (SELECT NOT ('carrier' = ANY(allowed_roles)) FROM ref.delivery_transition_rules
   WHERE event='CONFIRM_RECEIPT'),
  'a carrier CANNOT confirm receipt on the recipient behalf');

-- Illegal transitions are rejected.
DO $$
DECLARE v_d UUID;
BEGIN
  INSERT INTO public.deliveries (kirim_id,carrier_id,status)
  VALUES (tests.uid('_kirim'), tests.uid('_carrier'), 'MATCHED')
  RETURNING id INTO v_d;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_delivery',v_d)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT throws_ok(
  format($$SELECT internal.fn_delivery_transition(%L,'CONFIRM_DELIVERY',%L,'carrier')$$,
         tests.uid('_delivery'), tests.uid('rahman')),
  NULL, NULL, 'cannot jump from MATCHED straight to DELIVERED');

SELECT throws_ok(
  format($$SELECT internal.fn_delivery_transition(%L,'START_PROCUREMENT',%L,'customer')$$,
         tests.uid('_delivery'), tests.uid('aisyah')),
  NULL, NULL, 'a customer cannot start procurement');

SELECT * FROM finish();
ROLLBACK;
