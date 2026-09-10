-- ============================================================================
-- 0016_seller_onboarding.sql / 0017_seller_product_rpcs.sql regression
-- tests: rpc_apply_seller, rpc_create_product, rpc_update_product, the
-- products moderation-column protection trigger (both INSERT and UPDATE),
-- and the product_images 6-photo limit trigger. Exercises each against a
-- real seller/product row, not a stand-in.
-- ============================================================================
BEGIN;
SELECT plan(19);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();

-- ── rpc_apply_seller ─────────────────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');

DO $$
DECLARE v_result JSONB; v_kepayan UUID;
BEGIN
  SELECT id INTO v_kepayan FROM public.communities WHERE name = 'Kg Kepayan Baru';
  v_result := public.rpc_apply_seller('Kedai Aisyah', v_kepayan, NULL);
  INSERT INTO tests.handles (handle, user_id) VALUES ('_seller', (v_result->>'seller_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

SELECT is((SELECT status::text FROM public.sellers WHERE id = tests.uid('_seller')),
  'NOT_STARTED', 'a new seller application starts at NOT_STARTED');

SELECT is((SELECT user_id FROM public.sellers WHERE id = tests.uid('_seller')),
  tests.uid('aisyah'), 'the application is owned by the applicant');

SELECT throws_ok(
  $$SELECT public.rpc_apply_seller('Second time', (SELECT id FROM public.communities WHERE name='Kg Kepayan Baru'), NULL)$$,
  NULL, NULL, 'a second application from the same user is rejected');

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_apply_seller('Nonexistent community', gen_random_uuid(), NULL)$$,
  NULL, NULL, 'applying with a nonexistent community is rejected');

-- ── rpc_create_product / rpc_update_product ─────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  $$SELECT public.rpc_create_product('Should fail', 'hasil-laut', 1000, 500)$$,
  NULL, NULL, 'rpc_create_product refuses a caller with no sellers row');

SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  $$SELECT public.rpc_create_product('Bad category', 'not-a-real-slug', 1000, 500)$$,
  NULL, NULL, 'rpc_create_product refuses an unknown category slug');

DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_create_product('Kraf Tangan RPC', 'kraf', 4500, 800, 'Anyaman tangan');
  INSERT INTO tests.handles (handle, user_id) VALUES ('_product_rpc', (v_result->>'id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product_rpc')),
  'draft', 'rpc_create_product always creates a draft, regardless of category');

SELECT public.rpc_update_product(tests.uid('_product_rpc'),
  'Kraf Tangan RPC (Updated)', 'kraf', 5000, 800);
SELECT is(
  (SELECT title || '|' || price_sen::text || '|' || status
   FROM public.products WHERE id = tests.uid('_product_rpc')),
  'Kraf Tangan RPC (Updated)|5000|draft',
  'rpc_update_product updates editable fields and leaves status untouched');

-- ── products moderation-column protection ───────────────────────────────────
SELECT tests.authenticate_as('aisyah');

DO $$
DECLARE v_product UUID; v_cat UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug = 'hasil-laut';
  INSERT INTO public.products (seller_id, title, category_id, price_sen, weight_grams)
  VALUES (tests.uid('_seller'), 'Ikan Bilis Rehearsal', v_cat, 1500, 500)
  RETURNING id INTO v_product;
  INSERT INTO tests.handles (handle, user_id) VALUES ('_product', v_product)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product')),
  'draft', 'a new product starts as draft, direct-write RLS allows it');

-- The INSERT-time bypass this trigger also closes: products_write permits a
-- direct INSERT, and nothing stopped the client from putting status='active'
-- straight in the insert payload before this trigger covered INSERT too.
DO $$
DECLARE v_product2 UUID; v_cat UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug = 'hasil-laut';
  INSERT INTO public.products (seller_id, title, category_id, price_sen, weight_grams, status)
  VALUES (tests.uid('_seller'), 'Insert Bypass Attempt', v_cat, 1000, 500, 'active')
  RETURNING id INTO v_product2;
  INSERT INTO tests.handles (handle, user_id) VALUES ('_product_bypass', v_product2)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product_bypass')),
  'draft', 'setting status=active in the INSERT payload itself is also refused');

-- The bypass this trigger exists to close: RLS alone lets a seller UPDATE
-- their own product's status to anything, including straight to 'active'.
UPDATE public.products SET status = 'active', compliance_note = 'self-approved'
  WHERE id = tests.uid('_product');
SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product')),
  'draft', 'a seller cannot self-promote a product straight to active');
SELECT is((SELECT compliance_note FROM public.products WHERE id = tests.uid('_product')),
  NULL, 'a seller cannot write their own compliance_note');

-- A legitimate self-service transition still works.
UPDATE public.products SET status = 'pending_review' WHERE id = tests.uid('_product');
SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product')),
  'pending_review', 'draft -> pending_review (submit for review) is allowed');

-- Admin can do what the seller cannot -- but not via a raw UPDATE.
-- products_write (pre-existing RLS, confirmed live) is seller-own-row
-- only, with no admin clause at all: an admin's direct UPDATE here is
-- silently filtered to zero rows by RLS before the moderation trigger is
-- even reached (this is exactly what 0018_admin_product_review.sql's own
-- header documents finding). rpc_admin_set_product_status is the actual
-- admin write path.
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_set_product_status(%L, 'active')$$, tests.uid('_product')),
  NULL, NULL, 'a non-admin caller cannot call rpc_admin_set_product_status at all');

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_product'), 'active');
SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product')),
  'active', 'admin_ops can approve a product via rpc_admin_set_product_status');
SELECT is((SELECT approved_by FROM public.products WHERE id = tests.uid('_product')),
  tests.uid('admin'), 'approving records the approving admin');

-- Once active, the seller may pause/unpause it themselves (not a moderation
-- action -- just going dark), but still cannot jump back to active from
-- somewhere the trigger does not allow (e.g. 'rejected').
SELECT tests.authenticate_as('aisyah');
UPDATE public.products SET status = 'paused' WHERE id = tests.uid('_product');
SELECT is((SELECT status FROM public.products WHERE id = tests.uid('_product')),
  'paused', 'a seller may pause their own active listing');

-- ── product_images: 6-photo limit ───────────────────────────────────────────
DO $$
DECLARE i INT;
BEGIN
  FOR i IN 1..6 LOOP
    INSERT INTO public.product_images (product_id, storage_path, sort_order)
    VALUES (tests.uid('_product'), tests.uid('aisyah')::text || '/' || tests.uid('_product')::text || '/' || i || '.jpg', i);
  END LOOP;
END $$;

SELECT is((SELECT count(*)::int FROM public.product_images WHERE product_id = tests.uid('_product')),
  6, 'six product images were accepted');

SELECT throws_ok(
  format($$INSERT INTO public.product_images (product_id, storage_path, sort_order)
           VALUES (%L, %L, 7)$$,
         tests.uid('_product'), tests.uid('aisyah')::text || '/' || tests.uid('_product')::text || '/7.jpg'),
  NULL, NULL, 'a seventh image on the same product is rejected');

SELECT tests.clear_auth();
SELECT * FROM finish();
ROLLBACK;
