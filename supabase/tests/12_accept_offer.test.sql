-- ============================================================================
-- rpc_accept_offer (0012/0013 board-matching RPC) had zero automated
-- coverage anywhere in this suite before this file -- discovered during
-- P1-B's live-backend carrier validation
-- (docs/CARRIER_DEVICE_VALIDATION.md), which rehearsed every one of these
-- paths by hand, once, against the real Supabase project. This closes that
-- gap with real, replayable regression coverage for the same paths.
-- ============================================================================
BEGIN;
SELECT plan(11);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();

-- ── STATE_ACTOR_NOT_PERMITTED: non-carrier caller ──────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_accept_offer(%L,%L)$$, tests.uid('_trip'), tests.uid('_kirim')),
  NULL, NULL, 'a non-carrier caller cannot accept a board offer');

-- ── successful accept ───────────────────────────────────────────────────────
SELECT tests.authenticate_as('rahman');

DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles (handle,user_id) VALUES ('_delivery',(v_result->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT status::text FROM public.kirim_requests WHERE id=tests.uid('_kirim')),
  'MATCHED', 'accepting a POSTED offer moves the kirim to MATCHED');

SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('_delivery')),
  'MATCHED', 'a deliveries row is created with status MATCHED');

SELECT is((SELECT carrier_id FROM public.deliveries WHERE id=tests.uid('_delivery')),
  tests.uid('_carrier'), 'the delivery is assigned to the accepting carrier');

SELECT is((SELECT reserved_weight_grams FROM public.trips WHERE id=tests.uid('_trip')),
  2000, 'trip capacity is reserved for exactly the accepted kirim''s weight');

SELECT is((SELECT reserved_volume_cm3 FROM public.trips WHERE id=tests.uid('_trip')),
  8000, 'trip capacity is reserved for exactly the accepted kirim''s volume');

SELECT is((SELECT reserved_parcels FROM public.trips WHERE id=tests.uid('_trip')),
  1, 'trip capacity is reserved for exactly one parcel');

-- ── STATE_INVALID_TRANSITION: already matched, cannot be accepted twice ────
SELECT throws_ok(
  format($$SELECT public.rpc_accept_offer(%L,%L)$$, tests.uid('_trip'), tests.uid('_kirim')),
  NULL, NULL, 'a kirim already MATCHED cannot be accepted again');

-- ── SELF_DEALING: a carrier cannot accept their own posted kirim ───────────
-- rahman holds both 'customer' and 'carrier' roles in the fixture -- exactly
-- the account shape this check exists to guard.
SELECT tests.clear_auth();
DO $$
DECLARE v_kirim UUID; v_kk UUID; v_beluran UUID; v_cat UUID; v_addr UUID;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_cat     FROM ref.categories  WHERE slug='hasil-laut';
  SELECT id INTO v_addr    FROM public.addresses WHERE user_id=tests.uid('aisyah') LIMIT 1;
  INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
    item_description,category_id,est_weight_grams,budget_cap_sen,
    dest_address_id,origin_node_id,dest_node_id,handling_flags,total_escrow_sen)
  VALUES ('KK-SELFDEAL',tests.uid('rahman'),'BELI','POSTED',
    'Testing self-dealing',v_cat,500,1000,
    v_addr,v_beluran,v_kk,'{}',1500)
  RETURNING id INTO v_kirim;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_kirim_self',v_kirim)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_accept_offer(%L,%L)$$, tests.uid('_trip'), tests.uid('_kirim_self')),
  NULL, NULL, 'a carrier cannot accept their own posted kirim (self-dealing)');

-- ── FLOAT_LIMIT_EXCEEDED ────────────────────────────────────────────────────
-- seed_fixture's carrier has float_limit_sen=50000. Push existing exposure
-- to within 1000 sen of that limit, leaving no room for a new kirim whose
-- budget_cap_sen (2000) would breach it.
SELECT tests.clear_auth();
UPDATE public.carriers SET cod_held_sen = 49000 WHERE id = tests.uid('_carrier');

DO $$
DECLARE v_kirim UUID; v_kk UUID; v_beluran UUID; v_cat UUID; v_addr UUID;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_cat     FROM ref.categories  WHERE slug='hasil-laut';
  SELECT id INTO v_addr    FROM public.addresses WHERE user_id=tests.uid('aisyah') LIMIT 1;
  INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
    item_description,category_id,est_weight_grams,budget_cap_sen,
    dest_address_id,origin_node_id,dest_node_id,handling_flags,total_escrow_sen)
  VALUES ('KK-FLOATLIM',tests.uid('aisyah'),'BELI','POSTED',
    'Testing float limit',v_cat,500,2000,
    v_addr,v_beluran,v_kk,'{}',3000)
  RETURNING id INTO v_kirim;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_kirim_float',v_kirim)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_accept_offer(%L,%L)$$, tests.uid('_trip'), tests.uid('_kirim_float')),
  NULL, NULL, 'accepting an offer that would breach the carrier''s float limit is rejected');

SELECT tests.clear_auth();
UPDATE public.carriers SET cod_held_sen = 0 WHERE id = tests.uid('_carrier');

-- ── CAPACITY_EXCEEDED, surfaced end-to-end through rpc_accept_offer ────────
-- fn_reserve_capacity's own boundary is already covered directly in
-- 01_constraints.test.sql; this proves rpc_accept_offer actually reaches
-- that guard rather than swallowing or bypassing it.
DO $$
DECLARE v_trip2 UUID; v_kirim UUID; v_kk UUID; v_beluran UUID; v_cat UUID;
         v_addr UUID; v_vehicle UUID;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_cat     FROM ref.categories  WHERE slug='hasil-laut';
  SELECT id INTO v_addr    FROM public.addresses WHERE user_id=tests.uid('aisyah') LIMIT 1;
  SELECT id INTO v_vehicle FROM public.vehicles WHERE carrier_id=tests.uid('_carrier');

  INSERT INTO public.trips (carrier_id,vehicle_id,status,origin_node_id,dest_node_id,
    corridor_nodes,depart_at,capacity_weight_grams,capacity_volume_cm3,capacity_parcels)
  VALUES (tests.uid('_carrier'),v_vehicle,'BOARDING',v_beluran,v_kk,
    ARRAY[v_beluran,v_kk], now()+interval '1 day', 100, 100, 1)
  RETURNING id INTO v_trip2;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_trip_tiny',v_trip2)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
    item_description,category_id,est_weight_grams,budget_cap_sen,
    dest_address_id,origin_node_id,dest_node_id,handling_flags,total_escrow_sen)
  VALUES ('KK-CAPOVER',tests.uid('aisyah'),'BELI','POSTED',
    'Testing capacity exceeded',v_cat,5000,1000,
    v_addr,v_beluran,v_kk,'{}',1500)
  RETURNING id INTO v_kirim;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_kirim_cap',v_kirim)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_accept_offer(%L,%L)$$, tests.uid('_trip_tiny'), tests.uid('_kirim_cap')),
  NULL, NULL, 'accepting an offer that exceeds the trip''s remaining capacity is rejected');

SELECT tests.clear_auth();
SELECT * FROM finish();
ROLLBACK;
