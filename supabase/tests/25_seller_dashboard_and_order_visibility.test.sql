-- ============================================================================
-- PHASE 2 / P2-C: seller dashboard aggregate + seller order/delivery/payment
-- visibility (0035_seller_dashboard_and_order_visibility.sql).
--
-- Both RPCs are read-only. rpc_seller_dashboard scopes every count to the
-- caller's own seller_id; rpc_seller_order_status is the seller-side
-- equivalent of rpc_get_payment_status (0034) -- ownership-checked, and
-- deliberately does NOT imply kirim_select/deliveries_select now cover a
-- seller (they still don't; this file doesn't touch RLS at all).
-- ============================================================================
BEGIN;
SELECT plan(22);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p25_seller',  '+60128882501', ARRAY['customer','seller']);
SELECT tests.create_user('p25_other',   '+60128882502', ARRAY['customer','seller']);

DO $$
DECLARE v_s UUID; v_other_s UUID; v_cat UUID; v_kepayan UUID;
        v_p UUID; v_p_low UUID; v_other_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p25_seller'),'Kedai P25',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p25_other'),'Kedai P25 Lain',v_kepayan,'APPROVED',1000) RETURNING id INTO v_other_s;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P25',v_cat,2000,500) RETURNING id INTO v_p;
  -- A second product, deliberately kept low on stock, to test the dashboard's
  -- low_stock_count without disturbing the order-flow product above.
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P25 Nipis',v_cat,1000,300) RETURNING id INTO v_p_low;
  -- Another seller's product: proves the dashboard counts don't leak across
  -- sellers even though both rows sit in the same table.
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_other_s,'Sayur Lain',v_cat,2000,500) RETURNING id INTO v_other_p;

  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_s',v_s),('_p',v_p),('_p_low',v_p_low),('_other_p',v_other_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p'), 'active');
SELECT public.rpc_admin_set_product_status(tests.uid('_p_low'), 'active');
SELECT public.rpc_admin_set_product_status(tests.uid('_other_p'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20, safety_stock = 5 WHERE product_id = tests.uid('_p');
UPDATE public.inventory SET on_hand = 2,  safety_stock = 5 WHERE product_id = tests.uid('_p_low');
UPDATE public.inventory SET on_hand = 20, safety_stock = 5 WHERE product_id = tests.uid('_other_p');

-- ── A. rpc_seller_dashboard ──────────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  $$SELECT public.rpc_seller_dashboard()$$,
  NULL, NULL, 'TEST A1: a non-seller cannot call the seller dashboard');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('p25_seller');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_seller_dashboard();
  PERFORM set_config('tests.p25_dash', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is((current_setting('tests.p25_dash')::jsonb->>'product_count')::int, 2,
  'TEST A2: product_count is this seller''s own two products, not the third seller''s');
SELECT is((current_setting('tests.p25_dash')::jsonb->>'active_listings')::int, 2,
  'TEST A3: both of this seller''s products are active');
SELECT is((current_setting('tests.p25_dash')::jsonb->>'low_stock_count')::int, 1,
  'TEST A4: exactly the one product at/under its own safety stock counts as low');
SELECT is((current_setting('tests.p25_dash')::jsonb->>'pending_orders')::int, 0,
  'TEST A5: no orders exist yet');
SELECT is((current_setting('tests.p25_dash')::jsonb->>'completed_orders')::int, 0,
  'TEST A6: nothing settled yet either');

-- ── checkout: one order against p25_seller ─────────────────────────────────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim', id FROM public.kirim_requests WHERE order_id=tests.uid('_order')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

SELECT tests.authenticate_as('p25_seller');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_seller_dashboard();
  PERFORM set_config('tests.p25_dash2', r::text, false);
END $$;
SELECT tests.clear_auth();
SELECT is((current_setting('tests.p25_dash2')::jsonb->>'pending_orders')::int, 1,
  'TEST A7: the fresh COD order counts as pending');
SELECT is((current_setting('tests.p25_dash2')::jsonb->>'completed_orders')::int, 0,
  'TEST A8: not completed yet');

-- Narrow, direct manipulation -- this file tests rpc_seller_dashboard's own
-- counting logic, not the settlement pipeline (15_order_settlement.test.sql
-- already covers how an order actually reaches SETTLED).
UPDATE public.orders SET status = 'SETTLED' WHERE id = tests.uid('_order');

SELECT tests.authenticate_as('p25_seller');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_seller_dashboard();
  PERFORM set_config('tests.p25_dash3', r::text, false);
END $$;
SELECT tests.clear_auth();
SELECT is((current_setting('tests.p25_dash3')::jsonb->>'pending_orders')::int, 0,
  'TEST A9: a settled order no longer counts as pending');
SELECT is((current_setting('tests.p25_dash3')::jsonb->>'completed_orders')::int, 1,
  'TEST A10: and now counts as completed');

UPDATE public.orders SET status = 'PENDING_PAYMENT' WHERE id = tests.uid('_order');

-- ── B. rpc_seller_order_status ──────────────────────────────────────────────
SELECT throws_ok(
  format($$SELECT public.rpc_seller_order_status(%L)$$, tests.uid('_order')),
  NULL, NULL, 'TEST B1: unauthenticated is refused outright');

SELECT tests.authenticate_as('p25_other');
SELECT throws_ok(
  format($$SELECT public.rpc_seller_order_status(%L)$$, tests.uid('_order')),
  NULL, NULL, 'TEST B2: a different seller cannot read this order''s status');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('p25_seller');
SELECT throws_ok(
  $$SELECT public.rpc_seller_order_status(gen_random_uuid())$$,
  NULL, NULL, 'TEST B3: a nonexistent order id is refused, not silently empty');

DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_seller_order_status(tests.uid('_order'));
  PERFORM set_config('tests.p25_status', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is(current_setting('tests.p25_status')::jsonb->>'order_status', 'PENDING_PAYMENT',
  'TEST B4: order status is visible to the order''s own seller');
SELECT is(current_setting('tests.p25_status')::jsonb->>'payment_method', 'COD',
  'TEST B5: payment method is visible too');
SELECT is(current_setting('tests.p25_status')::jsonb->>'payment_status', 'COD_PENDING',
  'TEST B6: payment status, read from the same payments row the buyer sees');
SELECT ok((current_setting('tests.p25_status')::jsonb->>'delivery_id') IS NULL,
  'TEST B7: THE FIX -- no delivery has been matched to a carrier yet');
SELECT is((current_setting('tests.p25_status')::jsonb->>'carrier_assigned')::boolean, false,
  'TEST B8: so no carrier is assigned either');

-- ── once a carrier actually accepts the offer ───────────────────────────────
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT tests.authenticate_as('p25_seller');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_seller_order_status(tests.uid('_order'));
  PERFORM set_config('tests.p25_status2', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is((current_setting('tests.p25_status2')::jsonb->>'delivery_id')::uuid, tests.uid('_delivery'),
  'TEST B9: the seller now sees the matched delivery id');
SELECT is(current_setting('tests.p25_status2')::jsonb->>'delivery_status', 'MATCHED',
  'TEST B10: and its current status');
SELECT is((current_setting('tests.p25_status2')::jsonb->>'carrier_assigned')::boolean, true,
  'TEST B11: a carrier is now assigned');

-- ── the seller still has no general read on kirim_requests/deliveries ──────
-- This RPC is a narrow bypass, not a policy change -- confirm RLS itself is
-- untouched.
SELECT tests.authenticate_as('p25_seller');
SELECT is((SELECT count(*)::int FROM public.kirim_requests WHERE id = tests.uid('_kirim')),
  0, 'TEST B12: RLS still hides this kirim row from a plain seller-side select');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
