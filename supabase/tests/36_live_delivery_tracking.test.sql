-- ============================================================================
-- 0046_live_delivery_tracking.sql regression tests.
--
-- Drives a HANTAR kirim to PICKED_UP (mirrors 34_ratings.test.sql's own
-- real-transition-chain setup), then exercises rpc_update_delivery_location
-- (write window, ownership, coordinate validation) and
-- rpc_get_delivery_tracking (ownership, origin/destination, the live
-- position once one exists) plus the underlying RLS on
-- public.delivery_locations directly.
-- ============================================================================
BEGIN;
SELECT plan(21);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

DO $$
DECLARE
  v_beluran UUID; v_kk UUID; v_kepayan UUID; v_addr2 UUID;
  v_quote JSONB; v_kirim_created JSONB; v_kirim UUID; v_delivery UUID; r JSONB;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  -- A second address for aisyah, same reason 08_kirim_trip_creation.test.sql
  -- and 34_ratings.test.sql each create one: HANTAR needs a distinct pickup
  -- address from the single one seed_fixture provides.
  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
    community_id,landmark_note,nearest_node_id)
  VALUES (tests.uid('aisyah'),'Pejabat','Aisyah','+60128880001',
    v_kepayan,'Sebelah pasar', v_kk)
  RETURNING id INTO v_addr2;

  PERFORM tests.authenticate_as('aisyah');
  v_quote := public.rpc_quote_kirim('HANTAR','hasil-laut',1000,v_beluran,v_kk);
  v_kirim_created := public.rpc_create_kirim(
    (v_quote->>'quote_id')::uuid, 'Sekotak barang', tests.uid('_addr'), v_addr2);
  v_kirim := (v_kirim_created->>'kirim_id')::uuid;
  PERFORM tests.clear_auth();

  PERFORM tests.authenticate_as('rahman');
  r := public.rpc_accept_offer(tests.uid('_trip'), v_kirim);
  v_delivery := (r->>'delivery_id')::uuid;
  PERFORM tests.clear_auth();

  INSERT INTO tests.handles(handle,user_id) VALUES ('_kirim36', v_kirim), ('_delivery36', v_delivery)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- ── write is refused before pickup ──────────────────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('_delivery36')),
  'MATCHED', 'setup: the delivery starts MATCHED, before any pickup');
SELECT throws_ok(
  format($$SELECT public.rpc_update_delivery_location(%L, 5.9749, 116.0724)$$, tests.uid('_delivery36')),
  NULL, NULL, 'a location update is refused before the delivery is picked up');

-- ── drive it to PICKED_UP (the real transition chain, not a forced status) ──
SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery36'),'pickup','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery36'),'GO_TO_PICKUP');
SELECT is(
  (public.rpc_delivery_transition(tests.uid('_delivery36'),'CONFIRM_PICKUP'))->>'status',
  'PICKED_UP', 'the delivery reaches PICKED_UP via the real transition chain');

-- ── ownership and validation on the write path ──────────────────────────────
SELECT tests.clear_auth();
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_update_delivery_location(%L, 5.9749, 116.0724)$$, tests.uid('_delivery36')),
  NULL, NULL, 'a carrier not assigned to this delivery cannot post its location');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_update_delivery_location(%L, 91, 116.0724)$$, tests.uid('_delivery36')),
  NULL, NULL, 'a latitude outside -90..90 is rejected');
SELECT throws_ok(
  format($$SELECT public.rpc_update_delivery_location(%L, 5.9749, 181)$$, tests.uid('_delivery36')),
  NULL, NULL, 'a longitude outside -180..180 is rejected');

SELECT lives_ok(
  format($$SELECT public.rpc_update_delivery_location(%L, 5.9749, 116.0724, 45.0, 32.5, 8.0)$$,
    tests.uid('_delivery36')),
  'the assigned carrier can post a location while the delivery is in transit');
SELECT tests.clear_auth();

-- ── the row landed, upserted (not appended) ─────────────────────────────────
SELECT is((SELECT count(*)::int FROM public.delivery_locations WHERE delivery_id=tests.uid('_delivery36')),
  1, 'exactly one row exists for this delivery');
SELECT is(
  (SELECT round(ST_Y(geog::geometry)::numeric, 4) FROM public.delivery_locations
    WHERE delivery_id=tests.uid('_delivery36')),
  5.9749::numeric, 'the stored latitude round-trips through ST_MakePoint/ST_Y');
SELECT is(
  (SELECT round(ST_X(geog::geometry)::numeric, 4) FROM public.delivery_locations
    WHERE delivery_id=tests.uid('_delivery36')),
  116.0724::numeric, 'the stored longitude round-trips through ST_MakePoint/ST_X');

SELECT tests.authenticate_as('rahman');
SELECT lives_ok(
  format($$SELECT public.rpc_update_delivery_location(%L, 6.0, 116.1)$$, tests.uid('_delivery36')),
  'a second update from the same carrier is accepted');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.delivery_locations WHERE delivery_id=tests.uid('_delivery36')),
  1, 'the second update upserts -- still exactly one row, not two');

-- ── RLS on the raw table (what Realtime itself enforces per subscriber) ────
SELECT tests.authenticate_as('aisyah');
SELECT ok(
  EXISTS (SELECT 1 FROM public.delivery_locations WHERE delivery_id=tests.uid('_delivery36')),
  'the requester (customer) can see the delivery''s own location row directly');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('stranger');
SELECT ok(
  NOT EXISTS (SELECT 1 FROM public.delivery_locations WHERE delivery_id=tests.uid('_delivery36')),
  'a stranger cannot see any row for this delivery');
SELECT throws_ok(
  format($$INSERT INTO public.delivery_locations (delivery_id, carrier_id, requester_id, geog)
           VALUES (%L, %L, %L, public.ST_MakePoint(0,0)::public.geography)$$,
    tests.uid('_delivery36'), tests.uid('_carrier'), tests.uid('aisyah')),
  NULL, NULL, 'a direct INSERT is refused -- rpc_update_delivery_location is the only write path');
SELECT tests.clear_auth();

-- ── rpc_get_delivery_tracking ────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_get_delivery_tracking(%L)$$, tests.uid('_delivery36')),
  NULL, NULL, 'a stranger cannot read the tracking summary either');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('aisyah');
SELECT is(
  public.rpc_get_delivery_tracking(tests.uid('_delivery36'))->>'delivery_status',
  'PICKED_UP', 'the tracking summary reports the delivery''s current status');
SELECT is(
  public.rpc_get_delivery_tracking(tests.uid('_delivery36'))->'origin'->>'name',
  'Beluran', 'the tracking summary resolves the origin route node');
SELECT is(
  public.rpc_get_delivery_tracking(tests.uid('_delivery36'))->'destination'->>'name',
  'Kota Kinabalu', 'the tracking summary resolves the destination route node');
SELECT is(
  (public.rpc_get_delivery_tracking(tests.uid('_delivery36'))->'carrier_location'->>'lat')::numeric,
  6.0::numeric, 'the tracking summary reports the carrier''s latest posted position');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT is(
  public.rpc_get_delivery_tracking(tests.uid('_delivery36'))->>'delivery_status',
  'PICKED_UP', 'the assigned carrier can also read their own delivery''s tracking summary');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
