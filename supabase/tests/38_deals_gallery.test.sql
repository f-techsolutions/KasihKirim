-- ============================================================================
-- 0048_promotions_gallery.sql regression tests.
--
-- Drives the buyer-facing deals gallery end to end: admin-only create/
-- update/delete on public.deal_campaigns (the raw write-path gap this
-- migration closes from day one, the same "no INSERT/UPDATE/DELETE grant,
-- RPC only" posture 0047 gives carrier_stock_lots' own lots_write removal),
-- and public.v_deal_campaigns' own join predicate -- a buyer must see an
-- active, in-window campaign whose product is still active, and nothing
-- else (inactive, not-yet-started, expired, or product no longer active).
-- ============================================================================
BEGIN;
SELECT plan(18);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- ── fixture: a seller + an active product to attach campaigns to ──────────
DO $$
DECLARE v_seller UUID; v_cat UUID; v_kepayan UUID; v_product UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status)
  VALUES (tests.uid('rahman'),'Kedai P38',v_kepayan,'APPROVED') RETURNING id INTO v_seller;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_seller,'Bayam P38',v_cat,500,300) RETURNING id INTO v_product;

  INSERT INTO tests.handles(handle,user_id) VALUES ('_seller38',v_seller),('_product38',v_product)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_product38'), 'active');
SELECT tests.clear_auth();

-- ── admin-only create ────────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_create_deal_campaign('Tawaran Bayam', %L, 'deal-banners/x.jpg')$$,
    tests.uid('_product38')),
  NULL, NULL, 'a non-admin cannot create a deal campaign');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT throws_ok(
  $$SELECT public.rpc_admin_create_deal_campaign('Tawaran Palsu', gen_random_uuid(), 'deal-banners/x.jpg')$$,
  NULL, NULL, 'a nonexistent product id is refused');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_create_deal_campaign('Tawaran Songsang', %L, 'deal-banners/x.jpg',
      p_starts_at := now(), p_ends_at := now() - interval '1 day')$$, tests.uid('_product38')),
  NULL, NULL, 'ends_at at or before starts_at is refused');

DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_admin_create_deal_campaign(
    'Tawaran Bayam', tests.uid('_product38'), 'deal-banners/bayam.jpg',
    p_subtitle := '10% off');
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_deal38', (v_result->>'id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

-- ── the buyer's own gallery read (v_deal_campaigns) ─────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT is(
  (SELECT product_title FROM public.v_deal_campaigns WHERE id = tests.uid('_deal38')),
  'Bayam P38', 'a buyer sees an active, in-window campaign for a live product');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_update_deal_campaign(tests.uid('_deal38'), p_is_active := false);
SELECT tests.clear_auth();
SELECT tests.authenticate_as('aisyah');
SELECT is(
  (SELECT count(*)::int FROM public.v_deal_campaigns WHERE id = tests.uid('_deal38')),
  0, 'an inactive campaign is hidden from the buyer gallery');
SELECT tests.clear_auth();
SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_update_deal_campaign(tests.uid('_deal38'), p_is_active := true);
SELECT tests.clear_auth();

UPDATE public.deal_campaigns SET starts_at = now() + interval '1 day' WHERE id = tests.uid('_deal38');
SELECT tests.authenticate_as('aisyah');
SELECT is(
  (SELECT count(*)::int FROM public.v_deal_campaigns WHERE id = tests.uid('_deal38')),
  0, 'a campaign whose window has not started yet is hidden');
SELECT tests.clear_auth();
UPDATE public.deal_campaigns SET starts_at = now() - interval '1 hour' WHERE id = tests.uid('_deal38');

-- now() is frozen for the whole transaction, so ends_at must use a
-- different offset than starts_at's own "now() - interval '1 hour'" just
-- above -- otherwise they'd land on the exact same instant and trip
-- deal_campaigns' own "ends_at > starts_at" check.
UPDATE public.deal_campaigns SET ends_at = now() - interval '30 minutes' WHERE id = tests.uid('_deal38');
SELECT tests.authenticate_as('aisyah');
SELECT is(
  (SELECT count(*)::int FROM public.v_deal_campaigns WHERE id = tests.uid('_deal38')),
  0, 'an expired campaign is hidden');
SELECT tests.clear_auth();
UPDATE public.deal_campaigns SET ends_at = NULL WHERE id = tests.uid('_deal38');

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_product38'), 'paused');
SELECT tests.clear_auth();
SELECT tests.authenticate_as('aisyah');
SELECT is(
  (SELECT count(*)::int FROM public.v_deal_campaigns WHERE id = tests.uid('_deal38')),
  0, 'a campaign whose product is no longer active is hidden even though the campaign itself is still active');
SELECT tests.clear_auth();
SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_product38'), 'active');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('aisyah');
SELECT is(
  (SELECT count(*)::int FROM public.v_deal_campaigns WHERE id = tests.uid('_deal38')),
  1, 'restoring the window/product/active flag makes the campaign visible again');
SELECT tests.clear_auth();

-- ── raw write-path gap check ─────────────────────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$UPDATE public.deal_campaigns SET title='Sneaky' WHERE id=%L$$, tests.uid('_deal38')),
  NULL, NULL, 'a raw UPDATE into deal_campaigns is refused -- the RPC is the only write path');
SELECT throws_ok(
  format($$INSERT INTO public.deal_campaigns (title,image_path,product_id,created_by)
           VALUES ('Sneaky', 'x.jpg', %L, %L)$$, tests.uid('_product38'), tests.uid('rahman')),
  NULL, NULL, 'a raw INSERT into deal_campaigns is refused');
SELECT tests.clear_auth();

-- ── admin update / delete ────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_update_deal_campaign(%L, p_sort_order := 5)$$, tests.uid('_deal38')),
  NULL, NULL, 'a non-admin cannot update a deal campaign');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT throws_ok(
  $$SELECT public.rpc_admin_update_deal_campaign(gen_random_uuid(), p_sort_order := 5)$$,
  NULL, NULL, 'updating a nonexistent campaign is refused');
SELECT is(
  (public.rpc_admin_update_deal_campaign(tests.uid('_deal38'), p_sort_order := 5))->>'id',
  tests.uid('_deal38')::text, 'an admin can update a campaign');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_delete_deal_campaign(%L)$$, tests.uid('_deal38')),
  NULL, NULL, 'a non-admin cannot delete a deal campaign');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT throws_ok(
  $$SELECT public.rpc_admin_delete_deal_campaign(gen_random_uuid())$$,
  NULL, NULL, 'deleting a nonexistent campaign is refused');
SELECT lives_ok(
  format($$SELECT public.rpc_admin_delete_deal_campaign(%L)$$, tests.uid('_deal38')),
  'an admin can delete a campaign');
SELECT tests.clear_auth();

SELECT is(
  (SELECT count(*)::int FROM public.deal_campaigns WHERE id = tests.uid('_deal38')),
  0, 'the campaign is actually gone after delete');

SELECT * FROM finish();
ROLLBACK;
