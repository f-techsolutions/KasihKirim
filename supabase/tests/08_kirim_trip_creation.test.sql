-- ============================================================================
-- rpc_create_kirim / rpc_create_trip (0012). Closes the two backend gaps
-- blocking Phase 4-6 of CLAUDE_IMPLEMENTATION_PLAN.md: customers could not
-- submit a Kirim and carriers could not announce a trip.
-- ============================================================================
BEGIN;
SELECT plan(14);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- A second address for aisyah, so HANTAR (which needs a distinct pickup
-- address) doesn't have to reuse the single one seed_fixture provides.
DO $$
DECLARE v_kk UUID; v_kepayan UUID; v_addr2 UUID;
BEGIN
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
    community_id,landmark_note,nearest_node_id)
  VALUES (tests.uid('aisyah'),'Pejabat','Aisyah','+60128880001',
    v_kepayan,'Sebelah pasar', v_kk)
  RETURNING id INTO v_addr2;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_addr2',v_addr2)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- ── rpc_create_kirim ─────────────────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');

DO $$
DECLARE v_beluran UUID; v_kk UUID; v_quote JSONB; v_kirim JSONB;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';

  v_quote := public.rpc_quote_kirim('HANTAR','hasil-laut',2000,v_beluran,v_kk);
  INSERT INTO tests.handles (handle,user_id)
    VALUES ('_quote_hantar',(v_quote->>'quote_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  v_kirim := public.rpc_create_kirim((v_quote->>'quote_id')::uuid, 'Ikan kering 2kg',
    tests.uid('_addr'), tests.uid('_addr2'));
  INSERT INTO tests.handles (handle,user_id) VALUES ('_kirim2',(v_kirim->>'kirim_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  -- A second, never-consumed HANTAR quote for the missing-origin-address case.
  v_quote := public.rpc_quote_kirim('HANTAR','hasil-laut',1500,v_beluran,v_kk);
  INSERT INTO tests.handles (handle,user_id)
    VALUES ('_quote_hantar2',(v_quote->>'quote_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  -- A BELI quote with the default (zero) budget, for the BELI-needs-budget case.
  v_quote := public.rpc_quote_kirim('BELI','hasil-laut',1500,v_beluran,v_kk);
  INSERT INTO tests.handles (handle,user_id)
    VALUES ('_quote_beli0',(v_quote->>'quote_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  -- A third HANTAR quote for the bad-destination-address case.
  v_quote := public.rpc_quote_kirim('HANTAR','hasil-laut',1500,v_beluran,v_kk);
  INSERT INTO tests.handles (handle,user_id)
    VALUES ('_quote_badaddr',(v_quote->>'quote_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT status::text FROM public.kirim_requests WHERE id=tests.uid('_kirim2')),
  'POSTED', 'rpc_create_kirim posts directly to POSTED, skipping DRAFT');

SELECT ok((SELECT reference_code FROM public.kirim_requests WHERE id=tests.uid('_kirim2'))
  LIKE 'KK-%', 'reference code follows the KK- convention');

SELECT is((SELECT origin_address_id FROM public.kirim_requests WHERE id=tests.uid('_kirim2')),
  tests.uid('_addr2'), 'the HANTAR pickup address is recorded');

SELECT throws_ok(
  format($$SELECT public.rpc_create_kirim(%L,'again',%L)$$,
         tests.uid('_quote_hantar'), tests.uid('_addr')),
  NULL, NULL, 'a consumed quote cannot be replayed into a second Kirim');

SELECT throws_ok(
  format($$SELECT public.rpc_create_kirim(%L,'no origin',%L)$$,
         tests.uid('_quote_hantar2'), tests.uid('_addr')),
  NULL, NULL, 'HANTAR without a pickup address is rejected');

SELECT throws_ok(
  format($$SELECT public.rpc_create_kirim(%L,'no budget',%L)$$,
         tests.uid('_quote_beli0'), tests.uid('_addr2')),
  NULL, NULL, 'BELI with a zero budget is rejected at creation, not just at the CHECK');

SELECT throws_ok(
  format($$SELECT public.rpc_create_kirim(%L,'bad dest',%L,%L)$$,
         tests.uid('_quote_badaddr'), gen_random_uuid(), tests.uid('_addr')),
  NULL, NULL, 'a nonexistent destination address is rejected');

-- The unconsumed HANTAR-missing-origin quote (_quote_hantar2) is still good;
-- reuse it to prove a quote is bound to its own requester.
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_create_kirim(%L,'not mine',%L)$$,
         tests.uid('_quote_hantar2'), tests.uid('_addr')),
  NULL, NULL, 'a quote cannot be consumed by anyone but the requester who priced it');

-- ── rpc_create_trip ──────────────────────────────────────────────────────────
DO $$
DECLARE v_beluran UUID; v_kk UUID; v_vehicle UUID; v_trip JSONB;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_vehicle FROM public.vehicles WHERE carrier_id=tests.uid('_carrier');

  v_trip := public.rpc_create_trip(v_vehicle, v_beluran, v_kk, now()+interval '2 days');
  INSERT INTO tests.handles (handle,user_id) VALUES ('_trip2',(v_trip->>'trip_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT status::text FROM public.trips WHERE id=tests.uid('_trip2')),
  'ANNOUNCED', 'rpc_create_trip announces directly');

SELECT is((SELECT capacity_weight_grams FROM public.trips WHERE id=tests.uid('_trip2')), 50000,
  'trip capacity is derived from the vehicle row, not client-supplied');

SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  $$SELECT public.rpc_create_trip(gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
      now()+interval '1 day')$$,
  NULL, NULL, 'a non-carrier cannot announce a trip');

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_trip(gen_random_uuid(),
      (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
      (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
      now()+interval '1 day')$$,
  NULL, NULL, 'a nonexistent or foreign vehicle is rejected');

SELECT throws_ok(
  $$SELECT public.rpc_create_trip(
      (SELECT id FROM public.vehicles WHERE carrier_id = tests.uid('_carrier')),
      (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
      (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
      now() - interval '1 hour')$$,
  NULL, NULL, 'a depart time in the past is rejected');

SELECT throws_ok(
  $$SELECT public.rpc_create_trip(
      (SELECT id FROM public.vehicles WHERE carrier_id = tests.uid('_carrier')),
      (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
      (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
      now() + interval '1 day')$$,
  NULL, NULL, 'identical origin and destination nodes are rejected');

SELECT * FROM finish();
ROLLBACK;
