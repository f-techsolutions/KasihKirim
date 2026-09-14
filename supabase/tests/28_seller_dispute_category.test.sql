-- ============================================================================
-- rpc_open_seller_dispute (0038_seller_dispute_category.sql).
--
-- 0032's own audit trail test (23_dispute_audit_trail.test.sql, TEST B5)
-- documented that a seller reaching OPEN_DISPUTE through the generic
-- rpc_delivery_transition gets category='other' by construction -- that
-- endpoint carries no free-text fields, unlike a customer's rpc_open_dispute.
-- This is the seller-facing counterpart that closes the gap: a real category
-- and description, same validation as rpc_open_dispute, authorized the same
-- way rpc_delivery_transition already authorizes a seller's own order.
-- ============================================================================
BEGIN;
SELECT plan(15);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p38_seller',   '+60128883801', ARRAY['customer','seller']);
SELECT tests.create_user('p38_seller2',  '+60128883802', ARRAY['customer','seller']);

-- ── a delivered, captured, undisputed marketplace order ────────────────────
DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p38_seller'),'Kedai P38',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P38',v_cat,1000,500) RETURNING id INTO v_p;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_s38',v_s),('_p38',v_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p38'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 10 WHERE product_id = tests.uid('_p38');

SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p38'), 2 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order38',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim38', id FROM public.kirim_requests WHERE order_id=tests.uid('_order38')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim38'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery38',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery38'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery38'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery38'),'GO_TO_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery38'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery38'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery38'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery38'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

-- ── a seller with no relationship to this order cannot use it either ──────
SELECT tests.authenticate_as('p38_seller2');
SELECT throws_ok(
  format($$SELECT public.rpc_open_seller_dispute(%L,'damaged','Barang sampai dalam keadaan rosak')$$,
         tests.uid('_delivery38')),
  NULL, NULL, 'TEST 1: an unrelated seller cannot dispute someone else''s order');
SELECT tests.clear_auth();

-- ── validation mirrors rpc_open_dispute's own ──────────────────────────────
SELECT tests.authenticate_as('p38_seller');
SELECT throws_ok(
  format($$SELECT public.rpc_open_seller_dispute(%L,'not_a_real_category','Barang sampai dalam keadaan rosak')$$,
         tests.uid('_delivery38')),
  NULL, NULL, 'TEST 2: an invalid category is refused, not silently coerced');
SELECT throws_ok(
  format($$SELECT public.rpc_open_seller_dispute(%L,'damaged','too short')$$,
         tests.uid('_delivery38')),
  NULL, NULL, 'TEST 3: a too-short description is refused');
SELECT tests.clear_auth();

-- ── the owning seller raises a real, non-'other' category ──────────────────
SELECT tests.authenticate_as('p38_seller');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_open_seller_dispute(tests.uid('_delivery38'),'damaged',
        'Sayur sampai dalam keadaan rosak semasa penghantaran');
  PERFORM set_config('tests.p38_dispute_id', r->>'dispute_id', false);
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT status FROM public.deliveries WHERE id=tests.uid('_delivery38')),
  'DISPUTED'::ref.kirim_status, 'TEST 4: the delivery moves to DISPUTED');
SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery38')),
  1, 'TEST 5: exactly one dispute row is created');
SELECT is((SELECT category FROM public.disputes
            WHERE id=current_setting('tests.p38_dispute_id')::uuid),
  'damaged', 'TEST 6: the seller''s real category is recorded, not the ''other'' default');
SELECT is((SELECT description FROM public.disputes
            WHERE id=current_setting('tests.p38_dispute_id')::uuid),
  'Sayur sampai dalam keadaan rosak semasa penghantaran',
  'TEST 7: the seller''s own free-text description is recorded verbatim');
SELECT is((SELECT raised_by FROM public.disputes
            WHERE id=current_setting('tests.p38_dispute_id')::uuid),
  tests.uid('p38_seller'), 'TEST 8: attributed to the seller who actually raised it');
SELECT is((SELECT against_id FROM public.disputes
            WHERE id=current_setting('tests.p38_dispute_id')::uuid),
  tests.uid('rahman'), 'TEST 9: a seller-raised dispute is routed against the assigned carrier');
SELECT ok((SELECT holds_escrow FROM public.disputes
            WHERE id=current_setting('tests.p38_dispute_id')::uuid),
  'TEST 10: the row holds escrow exactly as a customer-raised one does');
SELECT ok(EXISTS (SELECT 1 FROM audit.audit_logs
                   WHERE action='DISPUTE_OPENED' AND actor_id=tests.uid('p38_seller')
                     AND actor_role='seller'),
  'TEST 11: the seller''s own filing is in the audit trail, attributed to them');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery38')),
  'ESCROW_HELD_BY_DISPUTE',
  'TEST 12: settlement is blocked by the seller''s own dispute');

-- ── the same seller cannot re-file while it is still open ──────────────────
SELECT tests.authenticate_as('p38_seller');
SELECT throws_ok(
  format($$SELECT public.rpc_open_seller_dispute(%L,'wrong_item','Barang yang dihantar salah sepenuhnya')$$,
         tests.uid('_delivery38')),
  NULL, NULL, 'TEST 13: the same seller cannot file a second dispute while theirs is still open');
SELECT tests.clear_auth();

-- ── a non-PASARAN kirim has no seller party at all ─────────────────────────
-- seed_fixture's own _kirim is a plain BELI request (no order_id at all),
-- accepted into a fresh delivery here just for this one negative case.
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery38_beli',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT tests.authenticate_as('p38_seller');
SELECT throws_ok(
  format($$SELECT public.rpc_open_seller_dispute(%L,'damaged','Barang sampai dalam keadaan rosak')$$,
         tests.uid('_delivery38_beli')),
  NULL, NULL, 'TEST 14: a plain Kirim/Hantar delivery has no seller party to authorize');
SELECT tests.clear_auth();

-- ── resolving returns it to the settlement queue, exactly as rpc_open_dispute's does ──
SELECT tests.authenticate_as('admin');
SELECT is((public.rpc_admin_resolve_dispute(
             current_setting('tests.p38_dispute_id')::uuid,
             'RESOLVED_REJECTED','claim not upheld',0))->>'delivery_status',
  'DELIVERED', 'TEST 15: resolving the dispute returns the delivery to DELIVERED');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
