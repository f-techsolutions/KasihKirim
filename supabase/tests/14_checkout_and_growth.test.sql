-- ============================================================================
-- 0020_jualan_checkout_and_growth.sql regression tests: rpc_checkout,
-- rpc_claim_voucher, and the badge auto-award triggers. Every path here was
-- rehearsed once by hand against the real Supabase project first (throwaway
-- users, cleaned up afterward) -- this closes the gap with real, replayable
-- coverage for the same paths.
-- ============================================================================
BEGIN;
SELECT plan(22);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('siti',   '+60128880010', ARRAY['customer','seller']);
SELECT tests.create_user('minah',  '+60128880011', ARRAY['customer','seller']);
SELECT tests.create_user('zainab', '+60128880012', ARRAY['customer','seller']);
SELECT tests.create_user('halim',  '+60128880013', ARRAY['customer','carrier']);

-- ── fixture: two active sellers/products, one draft product, an inventory-
--    tracked product, a voucher campaign, and two badge-test actors left
--    unapproved so the AFTER UPDATE OF status trigger has something to fire
--    on (seed_fixture's own rahman/carrier is created pre-APPROVED, which
--    never fires an UPDATE). ─────────────────────────────────────────────────
DO $$
DECLARE
  v_seller1 UUID; v_seller2 UUID; v_seller3 UUID; v_carrier2 UUID;
  v_cat UUID; v_kepayan UUID;
  v_p_tracked UUID; v_p_untracked UUID; v_p_seller2 UUID; v_p_draft UUID;
  v_campaign UUID; v_campaign_inactive UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug='hasil-laut';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id, business_name, community_id, status)
  VALUES (tests.uid('siti'), 'Kedai Siti', v_kepayan, 'APPROVED') RETURNING id INTO v_seller1;
  INSERT INTO public.sellers (user_id, business_name, community_id, status)
  VALUES (tests.uid('minah'), 'Kedai Minah', v_kepayan, 'APPROVED') RETURNING id INTO v_seller2;
  -- zainab starts NOT_STARTED -- the badge trigger needs a real transition.
  INSERT INTO public.sellers (user_id, business_name, community_id, status)
  VALUES (tests.uid('zainab'), 'Kedai Zainab', v_kepayan, 'NOT_STARTED') RETURNING id INTO v_seller3;

  INSERT INTO public.carriers (user_id, status, completed_count)
  VALUES (tests.uid('halim'), 'NOT_STARTED', 0) RETURNING id INTO v_carrier2;

  INSERT INTO public.products (seller_id, title, category_id, price_sen, weight_grams)
  VALUES (v_seller1, 'Ikan Tracked', v_cat, 1000, 500) RETURNING id INTO v_p_tracked;
  INSERT INTO public.products (seller_id, title, category_id, price_sen, weight_grams)
  VALUES (v_seller1, 'Ikan Untracked', v_cat, 2000, 300) RETURNING id INTO v_p_untracked;
  INSERT INTO public.products (seller_id, title, category_id, price_sen, weight_grams)
  VALUES (v_seller2, 'Sayur Minah', v_cat, 500, 200) RETURNING id INTO v_p_seller2;
  INSERT INTO public.products (seller_id, title, category_id, price_sen, weight_grams)
  VALUES (v_seller1, 'Ikan Belum Lulus', v_cat, 700, 400) RETURNING id INTO v_p_draft;

  INSERT INTO public.inventory (product_id, on_hand, reserved) VALUES (v_p_tracked, 5, 0);

  INSERT INTO public.voucher_campaigns
    (code_prefix, name, discount_type, discount_value, min_order_sen,
     budget_ceiling_sen, per_user_limit, starts_at, ends_at, is_active)
  VALUES ('TEST14', 'Test Campaign 14', 'fixed', 500, 0, 100000, 1,
    now() - interval '1 hour', now() + interval '1 hour', true)
  RETURNING id INTO v_campaign;

  INSERT INTO public.voucher_campaigns
    (code_prefix, name, discount_type, discount_value, min_order_sen,
     budget_ceiling_sen, per_user_limit, starts_at, ends_at, is_active)
  VALUES ('EXPIRED14', 'Expired Campaign 14', 'fixed', 500, 0, 100000, 1,
    now() - interval '2 hours', now() - interval '1 hour', true)
  RETURNING id INTO v_campaign_inactive;

  INSERT INTO tests.handles (handle, user_id) VALUES
    ('_seller1', v_seller1), ('_seller2', v_seller2), ('_seller3', v_seller3),
    ('_carrier2', v_carrier2),
    ('_p_tracked', v_p_tracked), ('_p_untracked', v_p_untracked),
    ('_p_seller2', v_p_seller2), ('_p_draft', v_p_draft),
    ('_campaign', v_campaign), ('_campaign_inactive', v_campaign_inactive)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- admin activates the three real listings (v_p_draft is deliberately left
-- in draft -- that is the point of the PRODUCT_NOT_AVAILABLE case below).
SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p_tracked'), 'active');
SELECT public.rpc_admin_set_product_status(tests.uid('_p_untracked'), 'active');
SELECT public.rpc_admin_set_product_status(tests.uid('_p_seller2'), 'active');

-- ── rpc_checkout: auth / empty-cart guards ──────────────────────────────────
SELECT tests.clear_auth();
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L)$$, tests.uid('_addr')),
  NULL, NULL, 'rpc_checkout refuses an unauthenticated caller');

SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L)$$, tests.uid('_addr')),
  NULL, NULL, 'rpc_checkout refuses an empty cart');

-- ── happy path: two items, one seller, one inventory-tracked ───────────────
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah'))
  ON CONFLICT (user_id) DO NOTHING;
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_tracked'), 2 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_untracked'), 3 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');

DO $$
DECLARE v_result JSONB; v_order UUID;
BEGIN
  v_result := public.rpc_checkout(tests.uid('_addr'));
  v_order := (v_result->'orders'->0->>'order_id')::uuid;
  INSERT INTO tests.handles (handle, user_id) VALUES ('_order1', v_order)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT goods_subtotal_sen FROM public.orders WHERE id=tests.uid('_order1')),
  8000::bigint, 'checkout prices both lines from the live product row (2x1000 + 3x2000)');
SELECT is((SELECT commission_sen FROM public.orders WHERE id=tests.uid('_order1')),
  800::bigint, 'commission uses the default_seller_commission_bps config (10% of 8000)');
SELECT is((SELECT total_sen FROM public.orders WHERE id=tests.uid('_order1')),
  8000::bigint, 'total equals goods_subtotal_sen when no voucher is applied');
SELECT is((SELECT count(*)::int FROM public.order_items WHERE order_id=tests.uid('_order1')),
  2, 'one order_item per distinct cart line');
SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p_tracked')),
  2, 'stock is reserved only for the inventory-tracked product');
SELECT is((SELECT count(*)::int FROM public.cart_items ci
           JOIN public.carts c ON c.id=ci.cart_id WHERE c.user_id=tests.uid('aisyah')),
  0, 'checkout clears the cart it consumed');

-- ── PRODUCT_NOT_AVAILABLE: a draft product cannot be checked out ───────────
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_draft'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L)$$, tests.uid('_addr')),
  NULL, NULL, 'checkout refuses a product that is not active');
DELETE FROM public.cart_items ci USING public.carts c
  WHERE ci.cart_id=c.id AND c.user_id=tests.uid('aisyah');

-- ── INSUFFICIENT_STOCK: only 3 of the tracked product remain (5 - 2) ───────
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_tracked'), 10 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L)$$, tests.uid('_addr')),
  NULL, NULL, 'checkout refuses a quantity exceeding available stock');
SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p_tracked')),
  2, 'a failed checkout does not leave a partial stock reservation behind');
DELETE FROM public.cart_items ci USING public.carts c
  WHERE ci.cart_id=c.id AND c.user_id=tests.uid('aisyah');

-- ── VOUCHER_REQUIRES_SINGLE_SELLER: cart spans two sellers ─────────────────
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_untracked'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_seller2'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L, 'ANYTHING')$$, tests.uid('_addr')),
  NULL, NULL, 'a voucher code is refused on a cart spanning more than one seller');
DELETE FROM public.cart_items ci USING public.carts c
  WHERE ci.cart_id=c.id AND c.user_id=tests.uid('aisyah');

-- ── rpc_claim_voucher ────────────────────────────────────────────────────────
DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_claim_voucher(tests.uid('_campaign'));
  PERFORM set_config('tests.claimed_voucher_code', v_result->>'code', false);
END $$;
SELECT ok(current_setting('tests.claimed_voucher_code', true) IS NOT NULL,
  'rpc_claim_voucher issues a redeemable code from an active campaign');

SELECT throws_ok(
  format($$SELECT public.rpc_claim_voucher(%L)$$, tests.uid('_campaign')),
  NULL, NULL, 'a second claim past per_user_limit is refused');

SELECT throws_ok(
  format($$SELECT public.rpc_claim_voucher(%L)$$, tests.uid('_campaign_inactive')),
  NULL, NULL, 'claiming from an expired campaign is refused');

-- ── checkout with the claimed voucher (single-seller cart) ─────────────────
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_untracked'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');

DO $$
DECLARE v_result JSONB; v_order UUID; v_code TEXT := current_setting('tests.claimed_voucher_code', true);
BEGIN
  v_result := public.rpc_checkout(tests.uid('_addr'), v_code);
  v_order := (v_result->'orders'->0->>'order_id')::uuid;
  INSERT INTO tests.handles (handle, user_id) VALUES ('_order2', v_order)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT discount_sen FROM public.orders WHERE id=tests.uid('_order2')),
  500::bigint, 'the voucher''s fixed discount is applied to the order');
SELECT is((SELECT total_sen FROM public.orders WHERE id=tests.uid('_order2')),
  1500::bigint, 'total_sen reflects goods_subtotal_sen minus the voucher discount (2000 - 500)');

-- ── voucher cannot be redeemed twice ────────────────────────────────────────
INSERT INTO public.cart_items (cart_id, product_id, quantity)
  SELECT c.id, tests.uid('_p_untracked'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L, %L)$$,
    tests.uid('_addr'), current_setting('tests.claimed_voucher_code', true)),
  NULL, NULL, 'reusing an already-redeemed voucher code is refused');

-- ── badge auto-award (0022_deck_badge_awards.sql -- the real, deck-seeded
--    catalog from supabase/seed.sql, not the three this session first
--    guessed at in 0020 and then retracted) ─────────────────────────────────
SELECT tests.clear_auth();

DO $$
DECLARE v_addr1 UUID; v_addr2 UUID; v_kepayan UUID; v_muasnad UUID; v_cat UUID;
        v_beluran UUID; v_kk UUID; v_k1 UUID; v_k2 UUID;
BEGIN
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  SELECT id INTO v_muasnad FROM public.communities WHERE name='Kg Muasnad';
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='hasil-laut';
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';

  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,community_id,landmark_note)
  VALUES (tests.uid('zainab'),'A1','Zainab','+60128880012',v_kepayan,'Rumah pertama')
  RETURNING id INTO v_addr1;
  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,community_id,landmark_note)
  VALUES (tests.uid('zainab'),'A2','Zainab','+60128880012',v_muasnad,'Rumah kedua')
  RETURNING id INTO v_addr2;

  INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
    item_description,category_id,est_weight_grams,budget_cap_sen,
    dest_address_id,origin_node_id,dest_node_id,handling_flags,total_escrow_sen)
  VALUES ('KK-BADGE1',tests.uid('zainab'),'BELI','MATCHED','Badge test 1',v_cat,500,1000,
    v_addr1,v_beluran,v_kk,'{}',1500) RETURNING id INTO v_k1;
  INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
    item_description,category_id,est_weight_grams,budget_cap_sen,
    dest_address_id,origin_node_id,dest_node_id,handling_flags,total_escrow_sen)
  VALUES ('KK-BADGE2',tests.uid('zainab'),'BELI','MATCHED','Badge test 2',v_cat,500,1000,
    v_addr2,v_beluran,v_kk,'{}',1500) RETURNING id INTO v_k2;

  INSERT INTO tests.handles (handle,user_id) VALUES ('_kbadge1',v_k1),('_kbadge2',v_k2)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

UPDATE public.kirim_requests SET status='COMPLETED' WHERE id=tests.uid('_kbadge1');
SELECT is((SELECT count(*)::int FROM public.user_badges ub
           JOIN ref.badge_definitions bd ON bd.id=ub.badge_id
           WHERE ub.user_id=tests.uid('zainab') AND bd.slug='kirim-pertama'),
  1, 'a first COMPLETED kirim awards kirim-pertama');

UPDATE public.kirim_requests SET status='COMPLETED' WHERE id=tests.uid('_kbadge2');
SELECT is((SELECT count(*)::int FROM public.user_badges ub
           JOIN ref.badge_definitions bd ON bd.id=ub.badge_id
           WHERE ub.user_id=tests.uid('zainab') AND bd.slug='sokong-kampung'),
  1, 'COMPLETED kirim to a second distinct community awards sokong-kampung');

UPDATE public.carriers SET completed_count=25 WHERE id=tests.uid('_carrier2');
SELECT is((SELECT count(*)::int FROM public.user_badges ub
           JOIN ref.badge_definitions bd ON bd.id=ub.badge_id
           WHERE ub.user_id=tests.uid('halim') AND bd.slug='pembawa-setia'),
  1, 'carriers.completed_count reaching 25 awards pembawa-setia');

-- Re-crossing the same threshold is a no-op, not a second row.
UPDATE public.carriers SET completed_count=26 WHERE id=tests.uid('_carrier2');
SELECT is((SELECT count(*)::int FROM public.user_badges ub
           JOIN ref.badge_definitions bd ON bd.id=ub.badge_id
           WHERE ub.user_id=tests.uid('halim') AND bd.slug='pembawa-setia'),
  1, 'awarding the same badge twice does not create a duplicate row');

SELECT tests.clear_auth();
SELECT * FROM finish();
ROLLBACK;
