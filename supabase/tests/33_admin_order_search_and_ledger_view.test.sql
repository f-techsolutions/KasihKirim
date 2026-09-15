-- ============================================================================
-- 0043_admin_order_search_and_ledger_view.sql regression tests.
--
-- Exercises both remaining Phase 1 RPCs: rpc_admin_search_order against a
-- BELI kirim (seed_fixture's own 'KK-TEST01', no deliveries or payment yet)
-- and against a PASARAN kirim produced by a real rpc_checkout call (which
-- also opens the internal.payments COD intent rpc_admin_recent_payments
-- reads), plus the admin gate on both RPCs.
-- ============================================================================
BEGIN;
SELECT plan(20);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p33_seller', '+60128881933', ARRAY['customer','seller']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p1 UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p33_seller'),'Kedai P33',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Bayam P33',v_cat,1000,500) RETURNING id INTO v_p1;

  INSERT INTO tests.handles(handle,user_id) VALUES ('_s33',v_s),('_p33',v_p1)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p33'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20 WHERE product_id = tests.uid('_p33');

-- ── produce a real PASARAN order + COD payment intent via checkout ─────────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p33'), 3 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');

DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_order33',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

INSERT INTO tests.handles(handle,user_id)
SELECT '_pasaran_kirim', id FROM public.kirim_requests WHERE order_id = tests.uid('_order33')
ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

-- ── admin gate ───────────────────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  $$SELECT public.rpc_admin_search_order('KK-TEST01')$$,
  NULL, NULL, 'a non-admin cannot search orders/deliveries');
SELECT throws_ok(
  $$SELECT public.rpc_admin_recent_payments()$$,
  NULL, NULL, 'a non-admin cannot view recent payments');
SELECT tests.clear_auth();

-- ── rpc_admin_search_order: BELI kirim, no deliveries or payment yet ────────
SELECT tests.authenticate_as('admin');
SELECT is(
  (public.rpc_admin_search_order('KK-TEST01')->>'found')::boolean,
  true, 'the seed BELI kirim is found by its exact reference code');
SELECT is(
  public.rpc_admin_search_order('KK-TEST01')->>'kirim_type',
  'BELI', 'the found record reports the correct kirim_type');
SELECT is(
  public.rpc_admin_search_order('KK-TEST01')->'deliveries',
  '[]'::jsonb, 'a kirim with no delivery attempts yet reports an empty deliveries array');
SELECT is(
  public.rpc_admin_search_order('KK-TEST01')->'payment',
  'null'::jsonb, 'a kirim with no internal.payments row reports payment as null, not an error');
SELECT is(
  (public.rpc_admin_search_order('TEST01')->>'kirim_id')::uuid,
  tests.uid('_kirim'), 'a partial (ILIKE) match on the reference code also finds the kirim');

SELECT is(
  (public.rpc_admin_search_order('no-such-reference-xyz')->>'found')::boolean,
  false, 'a query matching nothing returns found:false rather than raising');
SELECT is(
  (public.rpc_admin_search_order('')->>'found')::boolean,
  false, 'an empty query returns found:false rather than matching everything');
SELECT is(
  (public.rpc_admin_search_order('   ')->>'found')::boolean,
  false, 'a whitespace-only query is treated the same as empty');

-- ── rpc_admin_search_order: PASARAN kirim reached via its order's own code ──
SELECT is(
  (public.rpc_admin_search_order(
     (SELECT reference_code FROM public.orders WHERE id = tests.uid('_order33'))
   )->>'kirim_id')::uuid,
  tests.uid('_pasaran_kirim'),
  'searching by a PASARAN order''s own reference code falls back to its wrapping kirim');
SELECT is(
  public.rpc_admin_search_order(
    (SELECT reference_code FROM public.orders WHERE id = tests.uid('_order33'))
  )->>'kirim_type',
  'PASARAN', 'the record reached via the order fallback reports kirim_type PASARAN');
SELECT is(
  (public.rpc_admin_search_order(
     (SELECT reference_code FROM public.orders WHERE id = tests.uid('_order33'))
   )->'order'->>'id')::uuid,
  tests.uid('_order33'), 'the nested order object is the same order that was searched for');
SELECT is(
  public.rpc_admin_search_order(
    (SELECT reference_code FROM public.orders WHERE id = tests.uid('_order33'))
  )->'payment'->>'status',
  'COD_PENDING', 'the checkout''s COD payment intent is surfaced as the kirim''s payment');
SELECT is(
  (public.rpc_admin_search_order(
     (SELECT reference_code FROM public.orders WHERE id = tests.uid('_order33'))
   )->'payment'->>'amount_sen')::bigint,
  (SELECT total_sen FROM public.orders WHERE id = tests.uid('_order33')),
  'the payment amount matches the order total');

-- Searching by the PASARAN kirim's own reference code (not the order's) is a
-- direct kirim_requests hit -- no fallback needed -- and resolves the same kirim.
SELECT is(
  (public.rpc_admin_search_order(
     (SELECT reference_code FROM public.kirim_requests WHERE id = tests.uid('_pasaran_kirim'))
   )->>'kirim_id')::uuid,
  tests.uid('_pasaran_kirim'),
  'searching by the PASARAN kirim''s own reference code finds it directly');

-- ── rpc_admin_recent_payments ────────────────────────────────────────────────
SELECT ok(
  (SELECT count(*)::int FROM public.rpc_admin_recent_payments()) >= 1,
  'the admin ledger view shows at least the checkout''s payment');
SELECT ok(
  EXISTS (
    SELECT 1 FROM public.rpc_admin_recent_payments()
     WHERE reference_type = 'order' AND reference_id = tests.uid('_order33')
       AND status = 'COD_PENDING'),
  'the checkout''s order-referenced COD payment intent appears in the ledger view');
SELECT is(
  (SELECT payer_name FROM public.rpc_admin_recent_payments()
    WHERE reference_type = 'order' AND reference_id = tests.uid('_order33')),
  'aisyah', 'the payer is resolved to a display name, not left as a bare id');
SELECT is(
  (SELECT count(*)::int FROM public.rpc_admin_recent_payments(1)),
  1, 'the p_limit parameter caps the number of rows returned');

SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
