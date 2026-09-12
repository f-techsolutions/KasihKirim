-- ============================================================================
-- PHASE 2 / P2-D: carrier board marketplace COD visibility
-- (0036_carrier_board_marketplace_cod_visibility.sql).
--
-- rpc_board() is read-only and grants a carrier nothing kirim_select's own
-- board clause didn't already grant them, plus one derived figure
-- (cod_total_sen) for a PASARAN listing. This file does not touch
-- orders_select/kirim_select RLS -- those stay exactly as they were.
-- ============================================================================
BEGIN;
SELECT plan(9);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- ── A. gating: only a carrier sees anything, and a plain kirim has no COD total ──
SELECT tests.authenticate_as('aisyah');
SELECT is(jsonb_array_length(public.rpc_board()), 0,
  'TEST A1: a non-carrier customer sees no board items');
SELECT tests.clear_auth();

SELECT is(jsonb_array_length(public.rpc_board()), 0,
  'TEST A2: an unauthenticated caller sees no board items either');

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_board();
  PERFORM set_config('tests.p26_board', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT ok(jsonb_array_length(current_setting('tests.p26_board')::jsonb) >= 1,
  'TEST A3: a carrier sees at least the seed fixture''s BELI board item');
SELECT ok(
  (SELECT elem->>'cod_total_sen' FROM jsonb_array_elements(current_setting('tests.p26_board')::jsonb) elem
    WHERE (elem->>'id')::uuid = tests.uid('_kirim')) IS NULL,
  'TEST A4: a BELI item carries no cod_total_sen -- it has no linked order');

-- ── B. a marketplace order posted to the board carries its true COD total ──
SELECT tests.create_user('p26_seller', '+60128882601', ARRAY['customer','seller']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='buah';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p26_seller'),'Kedai P26',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Buah P26',v_cat,3000,500) RETURNING id INTO v_p;

  INSERT INTO tests.handles(handle,user_id) VALUES ('_p26_p',v_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p26_p'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20, safety_stock = 5 WHERE product_id = tests.uid('_p26_p');

SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p26_p'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_p26_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_p26_kirim', id FROM public.kirim_requests WHERE order_id=tests.uid('_p26_order')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_board();
  PERFORM set_config('tests.p26_board2', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is(
  (SELECT elem->>'kirim_type' FROM jsonb_array_elements(current_setting('tests.p26_board2')::jsonb) elem
    WHERE (elem->>'id')::uuid = tests.uid('_p26_kirim')),
  'PASARAN',
  'TEST B1: the new marketplace order is posted to the board as a PASARAN kirim');
SELECT is(
  (SELECT (elem->>'cod_total_sen')::bigint FROM jsonb_array_elements(current_setting('tests.p26_board2')::jsonb) elem
    WHERE (elem->>'id')::uuid = tests.uid('_p26_kirim')),
  (SELECT total_sen FROM public.orders WHERE id = tests.uid('_p26_order')),
  'TEST B2: THE FIX -- cod_total_sen is the whole order total (goods + delivery), not just the carriage fee');
SELECT ok(
  (SELECT (elem->>'cod_total_sen')::bigint FROM jsonb_array_elements(current_setting('tests.p26_board2')::jsonb) elem
    WHERE (elem->>'id')::uuid = tests.uid('_p26_kirim'))
  >
  (SELECT delivery_fee_sen FROM public.kirim_requests WHERE id = tests.uid('_p26_kirim')),
  'TEST B3: and it is strictly more than the carriage-only delivery_fee_sen already shown for every kirim type');

-- ── C. once accepted, the job leaves the board ──────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_p26_kirim'));
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_board();
  PERFORM set_config('tests.p26_board3', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is(
  (SELECT count(*)::int FROM jsonb_array_elements(current_setting('tests.p26_board3')::jsonb) elem
    WHERE (elem->>'id')::uuid = tests.uid('_p26_kirim')),
  0,
  'TEST C1: an accepted job no longer appears on the board');

-- ── D. a HANTAR kirim reaches the board too, not just BELI/PASARAN ──────────
-- Production report: a customer's Kirim Barang (HANTAR) request posted from
-- Beluran to Kota Kinabalu -- an ordinary ALL-SABAH corridor already served
-- by the seed fixture's own trip -- was invisible on a carrier's board.
-- rpc_board's WHERE clause (status='POSTED' AND visibility='board' AND
-- deleted_at IS NULL AND authz.has_role('carrier')) never filters on
-- kirim_type, so a HANTAR row should appear exactly like the BELI row
-- TEST A3 already covers -- but nothing in this suite had ever posted a
-- HANTAR kirim through the real rpc_quote_kirim/rpc_create_kirim path and
-- then queried rpc_board() for it, so a regression specific to that
-- combination would have shipped unnoticed.
SELECT tests.authenticate_as('aisyah');
DO $$
DECLARE v_beluran UUID; v_kk UUID; v_kepayan UUID; v_origin UUID; v_quote JSONB; v_kirim JSONB;
BEGIN
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
    community_id,landmark_note,nearest_node_id)
  VALUES (tests.uid('aisyah'),'Pejabat','Aisyah','+60128880001',
    v_kepayan,'Sebelah pasar', v_beluran)
  RETURNING id INTO v_origin;

  v_quote := public.rpc_quote_kirim('HANTAR','hasil-laut',1800,v_beluran,v_kk);
  v_kirim := public.rpc_create_kirim((v_quote->>'quote_id')::uuid, 'Ikan bakar 2kg',
    tests.uid('_addr'), v_origin);
  INSERT INTO tests.handles (handle,user_id) VALUES ('_p26_hantar',(v_kirim->>'kirim_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_board();
  PERFORM set_config('tests.p26_board4', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is(
  (SELECT elem->>'kirim_type' FROM jsonb_array_elements(current_setting('tests.p26_board4')::jsonb) elem
    WHERE (elem->>'id')::uuid = tests.uid('_p26_hantar')),
  'HANTAR',
  'TEST D1: a POSTED HANTAR kirim (Beluran -> Kota Kinabalu) reaches the carrier board same as BELI/PASARAN');

SELECT * FROM finish();
ROLLBACK;
