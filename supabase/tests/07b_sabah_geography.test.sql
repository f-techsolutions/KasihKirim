-- ============================================================================
-- Sabah-wide geography (0008). Split from 07_compliance.test.sql: one TAP
-- plan per file, so test numbering stays monotonic and unique.
-- Product scope is Sabah; Beluran/Paitan/KK are pilot locations only.
-- ============================================================================
BEGIN;
SELECT plan(7);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

SELECT is((SELECT count(*) FROM ref.divisions), 5::bigint,
  'all five Sabah divisions present');

SELECT ok((SELECT count(*) FROM ref.districts WHERE NOT is_sub_district) >= 27,
  'all 27 Sabah districts represented from day one, not just the pilot');

SELECT is((SELECT count(*) FROM ref.districts WHERE status='PILOT'
             AND NOT is_sub_district), 2::bigint,
  'exactly two full districts are PILOT (Beluran, Kota Kinabalu)');

SELECT ok((SELECT count(*) FROM ref.districts WHERE status='PLANNED') >= 24,
  'the rest of Sabah is PLANNED and openable by configuration');

-- §10: Paitan sits under Beluran, it is not a root location.
SELECT is(
  (SELECT p.name FROM ref.districts d JOIN ref.districts p ON p.id=d.parent_district_id
    WHERE d.code='SBH-BLR-PTN'),
  'Beluran', 'Paitan is a sub-district of Beluran, not a root district');

-- §5: water transport is first-class.
SELECT is((SELECT medium FROM ref.transport_types WHERE code='BOAT'),
  'water', 'BOAT is registered as a first-class water transport type');

-- §8: serviceability is a server decision, never an app conditional.
SELECT is(
  (SELECT (internal.fn_check_serviceability(
     (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
     (SELECT id FROM ref.route_nodes WHERE name='Sandakan')) ->> 'reason')),
  'DESTINATION_NOT_ACTIVE',
  'a PLANNED district is correctly reported as not yet serviceable');

SELECT * FROM finish();
ROLLBACK;
