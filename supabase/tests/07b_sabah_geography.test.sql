-- ============================================================================
-- Sabah-wide geography (0008). Split from 07_compliance.test.sql: one TAP
-- plan per file, so test numbering stays monotonic and unique.
-- Product scope is Sabah; Beluran/Paitan/KK are pilot locations only.
-- ============================================================================
BEGIN;
SELECT plan(11);
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
-- All four states are asserted, so a regression in any one of them is caught
-- rather than only the case that originally failed.

-- KNOWN + PLANNED -> not yet open (NOT "unknown")
SELECT is(
  (SELECT (internal.fn_check_serviceability(
     (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
     (SELECT id FROM ref.route_nodes WHERE name='Sandakan')) ->> 'reason')),
  'DESTINATION_NOT_ACTIVE',
  'a PLANNED district is correctly reported as not yet serviceable');

-- KNOWN + PLANNED on the ORIGIN side reports the origin, not the destination
SELECT is(
  (SELECT (internal.fn_check_serviceability(
     (SELECT id FROM ref.route_nodes WHERE name='Tawau'),
     (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu')) ->> 'reason')),
  'ORIGIN_NOT_ACTIVE',
  'a PLANNED origin is reported as ORIGIN_NOT_ACTIVE');

-- GENUINELY UNMAPPED input -> GEOGRAPHY_UNKNOWN (and only this case)
SELECT is(
  (SELECT (internal.fn_check_serviceability(
     (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
     '00000000-0000-0000-0000-000000000000'::uuid) ->> 'reason')),
  'GEOGRAPHY_UNKNOWN',
  'an unmapped destination is reported as GEOGRAPHY_UNKNOWN');

-- KNOWN + ACTIVE both ends, connected by the seeded corridor -> serviceable
SELECT is(
  (SELECT (internal.fn_check_serviceability(
     (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
     (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu')) ->> 'serviceable')),
  'true',
  'an ACTIVE origin and destination on the seeded corridor is serviceable');

-- every district resolves to geography: identity is complete Sabah-wide
SELECT is(
  (SELECT count(*) FROM ref.districts d
    WHERE NOT EXISTS (SELECT 1 FROM ref.route_nodes n WHERE n.district_id = d.id)),
  0::bigint,
  'every Sabah district resolves to at least one route node');

SELECT * FROM finish();
ROLLBACK;
