-- ============================================================================
-- P1-A regression: seller product + stock (0025_seller_product_stock.sql).
--
-- The headline case is TEST 5. Before 0025, a product with no row in
-- public.inventory sold without limit: rpc_checkout's reservation UPDATE
-- matched nothing, and its guard only raised when a row already existed.
-- ============================================================================
BEGIN;
SELECT plan(23);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p16_seller',  '+60128881601', ARRAY['customer','seller']);
SELECT tests.create_user('p16_seller2', '+60128881602', ARRAY['customer','seller']);

DO $$
DECLARE v_s1 UUID; v_s2 UUID; v_cat UUID; v_kepayan UUID; v_p1 UUID; v_p2 UUID; v_p3 UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p16_seller'),'Kedai P16',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s1;
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p16_seller2'),'Kedai P16b',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s2;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s1,'Bayam P16',v_cat,500,400) RETURNING id INTO v_p1;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s2,'Kangkung P16',v_cat,600,400) RETURNING id INTO v_p2;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s1,'Terung P16',v_cat,700,400) RETURNING id INTO v_p3;

  INSERT INTO tests.handles(handle,user_id) VALUES
    ('_s1',v_s1),('_s2',v_s2),('_p1',v_p1),('_p2',v_p2),('_p3',v_p3)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- ── 1. a product exists with a stock row, opening at zero ──────────────────
SELECT is((SELECT count(*)::int FROM public.inventory WHERE product_id=tests.uid('_p1')),
  1, 'TEST 1a: creating a product creates its inventory row');
SELECT is((SELECT on_hand FROM public.inventory WHERE product_id=tests.uid('_p1')),
  0, 'TEST 1b: a new product opens at zero stock, not unlimited');

-- ── 2. seller sets and adjusts stock on their own product ─────────────────
SELECT tests.authenticate_as('p16_seller');
SELECT is((public.rpc_set_stock(tests.uid('_p1'), 12)->>'on_hand')::int,
  12, 'TEST 2a: rpc_set_stock sets the seller''s own product stock');
SELECT is((public.rpc_adjust_stock(tests.uid('_p1'), -2, 'spoiled')->>'on_hand')::int,
  10, 'TEST 2b: rpc_adjust_stock applies a relative movement');
SELECT is((public.rpc_set_stock(tests.uid('_p1'), 10, 3)->>'safety_stock')::int,
  3, 'TEST 2c: rpc_set_stock records safety stock');

-- every movement is written to the append-only log
SELECT cmp_ok((SELECT count(*)::int FROM public.inventory_movements
                WHERE product_id=tests.uid('_p1')), '>=', 2,
  'TEST 2d: each stock change writes an inventory_movements row');

-- product update still works through the existing RPC
SELECT ok((public.rpc_update_product(
    tests.uid('_p1'), 'Bayam P16', 'sayur', 550::bigint, 400)) IS NOT NULL,
  'TEST 2e: a seller can update their own product price');
SELECT is((SELECT price_sen FROM public.products WHERE id=tests.uid('_p1')),
  550::bigint, 'TEST 2f: the new price is persisted server-side');

-- ── 3. a seller cannot touch another seller's product ─────────────────────
SELECT throws_ok(
  format($$SELECT public.rpc_set_stock(%L, 99)$$, tests.uid('_p2')),
  NULL, NULL, 'TEST 3a: a seller cannot set stock on another seller''s product');
SELECT throws_ok(
  format($$SELECT public.rpc_adjust_stock(%L, 5)$$, tests.uid('_p2')),
  NULL, NULL, 'TEST 3b: a seller cannot adjust another seller''s stock');
SELECT tests.clear_auth();
SELECT is((SELECT on_hand FROM public.inventory WHERE product_id=tests.uid('_p2')),
  0, 'TEST 3c: the other seller''s stock is untouched by the refused calls');

-- ── 4. an inactive product cannot be purchased ────────────────────────────
SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p1'), 'active');
SELECT tests.clear_auth();
SELECT is((SELECT status FROM public.products WHERE id=tests.uid('_p3')),
  'draft', 'TEST 4a: a product left unapproved stays in draft');

SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p3'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L)$$, tests.uid('_addr')),
  NULL, NULL, 'TEST 4b: checkout refuses a product that is not active');
DELETE FROM public.cart_items ci USING public.carts c
  WHERE ci.cart_id=c.id AND c.user_id=tests.uid('aisyah');

-- ── 5. THE OVERSELL HOLE: stock never set means nothing to sell ───────────
SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p3'), 'active');
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p3'), 4 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L)$$, tests.uid('_addr')),
  NULL, NULL,
  'TEST 5a: an active product whose seller never set stock cannot be bought at all');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.order_items WHERE product_id=tests.uid('_p3')),
  0, 'TEST 5b: no order line is created for an unstocked product');
SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p3')),
  0, 'TEST 5c: a refused checkout leaves no partial reservation');
DELETE FROM public.cart_items ci USING public.carts c
  WHERE ci.cart_id=c.id AND c.user_id=tests.uid('aisyah');

-- ── 6. stock cannot go negative, or below what is already reserved ────────
SELECT tests.authenticate_as('p16_seller');
SELECT throws_ok(
  format($$SELECT public.rpc_set_stock(%L, -1)$$, tests.uid('_p1')),
  NULL, NULL, 'TEST 6a: stock cannot be set negative');
SELECT throws_ok(
  format($$SELECT public.rpc_adjust_stock(%L, -100)$$, tests.uid('_p1')),
  NULL, NULL, 'TEST 6b: an adjustment cannot drive stock below zero');

SELECT tests.clear_auth();
UPDATE public.inventory SET reserved = 8 WHERE product_id = tests.uid('_p1');
SELECT tests.authenticate_as('p16_seller');
SELECT throws_ok(
  format($$SELECT public.rpc_set_stock(%L, 5)$$, tests.uid('_p1')),
  NULL, NULL, 'TEST 6c: a seller cannot cut stock below live reservations');
SELECT tests.clear_auth();
UPDATE public.inventory SET reserved = 0 WHERE product_id = tests.uid('_p1');

-- ── 7. concurrent purchase of the final unit cannot oversell ──────────────
-- Two sessions cannot be simulated inside one pgTAP transaction, so this
-- exercises the mechanism rpc_checkout actually relies on: the predicate and
-- the write are the same statement, so the loser matches no row.
UPDATE public.inventory SET on_hand = 1, reserved = 0 WHERE product_id = tests.uid('_p1');

DO $$
DECLARE v_first BOOLEAN; v_second BOOLEAN;
BEGIN
  UPDATE public.inventory SET reserved = reserved + 1
   WHERE product_id = tests.uid('_p1') AND on_hand - reserved >= 1;
  v_first := FOUND;
  UPDATE public.inventory SET reserved = reserved + 1
   WHERE product_id = tests.uid('_p1') AND on_hand - reserved >= 1;
  v_second := FOUND;
  PERFORM set_config('tests.p16_first',  v_first::text,  false);
  PERFORM set_config('tests.p16_second', v_second::text, false);
END $$;

SELECT ok(current_setting('tests.p16_first')::boolean,
  'TEST 7a: the first claim on the last unit succeeds');
SELECT ok(NOT current_setting('tests.p16_second')::boolean,
  'TEST 7b: the second claim on the same unit matches no row');
SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p1')),
  1, 'TEST 7c: exactly one unit ends up reserved');
SELECT ok(EXISTS (
  SELECT 1 FROM pg_constraint
   WHERE conrelid='public.inventory'::regclass AND conname='ck_inventory_not_oversold'),
  'TEST 7d: ck_inventory_not_oversold remains as the database-level backstop');

SELECT * FROM finish();
ROLLBACK;
