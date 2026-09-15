-- ============================================================================
-- P1-B / P1-C / P1-M regression: server-authoritative checkout, the payment
-- intent, and the discount refusal (0026_marketplace_checkout.sql).
--
-- Before 0026 an order left checkout with delivery_fee_sen = 0 and no
-- internal.payments row at all, so it could neither be carried nor paid nor
-- settled. A voucher could also set discount_sen, which 0024 then refuses at
-- settlement -- money in, nothing out.
-- ============================================================================
BEGIN;
SELECT plan(25);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p17_seller', '+60128881701', ARRAY['customer','seller']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p1 UUID; v_p2 UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  -- 20% seller commission, so the split is unambiguous in the assertions.
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p17_seller'),'Kedai P17',v_kepayan,'APPROVED',2000) RETURNING id INTO v_s;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Bayam P17',v_cat,1000,500) RETURNING id INTO v_p1;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Terung P17',v_cat,250,300) RETURNING id INTO v_p2;

  INSERT INTO tests.handles(handle,user_id) VALUES ('_s',v_s),('_p1',v_p1),('_p2',v_p2)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p1'), 'active');
SELECT public.rpc_admin_set_product_status(tests.uid('_p2'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20 WHERE product_id IN (tests.uid('_p1'), tests.uid('_p2'));

-- ── checkout: 2 x 1000 + 4 x 250 = 3000 goods ─────────────────────────────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p1'), 2 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p2'), 4 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');

DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
  PERFORM set_config('tests.p17_response', r::text, false);
END $$;
SELECT tests.clear_auth();

-- ── 8. subtotal is computed from the live product rows ────────────────────
SELECT is((SELECT goods_subtotal_sen FROM public.orders WHERE id=tests.uid('_order')),
  3000::bigint, 'TEST 8: goods subtotal is 2x1000 + 4x250, computed server-side');

-- ── 9. a delivery fee is actually priced ──────────────────────────────────
SELECT cmp_ok((SELECT delivery_fee_sen FROM public.orders WHERE id=tests.uid('_order')),
  '>', 0::bigint, 'TEST 9a: checkout prices a non-zero delivery fee');
SELECT is((SELECT o.delivery_fee_sen FROM public.orders o WHERE o.id=tests.uid('_order')),
  (SELECT q.delivery_fee_sen FROM public.orders o
     JOIN internal.quotes q ON q.id=o.quote_id WHERE o.id=tests.uid('_order')),
  'TEST 9b: the fee on the order is the fee on its quote, not a second number');
SELECT is((SELECT q.subject_type FROM public.orders o
             JOIN internal.quotes q ON q.id=o.quote_id WHERE o.id=tests.uid('_order')),
  'order', 'TEST 9c: the quote is labelled for an order, so rpc_create_kirim cannot consume it');

-- ── 10. commission ────────────────────────────────────────────────────────
SELECT is((SELECT commission_sen FROM public.orders WHERE id=tests.uid('_order')),
  600::bigint, 'TEST 10a: seller commission is the seller''s own bps on goods (20% of 3000)');
SELECT cmp_ok((SELECT q.commission_sen FROM public.orders o
                 JOIN internal.quotes q ON q.id=o.quote_id WHERE o.id=tests.uid('_order')),
  '>', 0::bigint, 'TEST 10b: the platform also takes a cut of the delivery fee');

-- ── 11. customer total ────────────────────────────────────────────────────
SELECT is((SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  (SELECT goods_subtotal_sen + delivery_fee_sen - discount_sen
     FROM public.orders WHERE id=tests.uid('_order')),
  'TEST 11a: total is goods + delivery - discount');
SELECT is((SELECT discount_sen FROM public.orders WHERE id=tests.uid('_order')),
  0::bigint, 'TEST 11b: no discount is applied');

-- ── 12. the client cannot supply or override any amount ───────────────────
-- rpc_checkout takes an address and a voucher code. There is no price,
-- quantity-price, fee or total parameter to override, by construction.
SELECT is((SELECT count(*)::int FROM information_schema.parameters
            WHERE specific_schema='public'
              AND specific_name IN (SELECT specific_name FROM information_schema.routines
                                     WHERE routine_schema='public' AND routine_name='rpc_checkout')
              AND parameter_name ~ '(price|total|fee|amount|commission|sen)'),
  0, 'TEST 12a: rpc_checkout accepts no monetary parameter at all');
SELECT is((SELECT line_total_sen FROM public.order_items
            WHERE order_id=tests.uid('_order') AND product_id=tests.uid('_p1')),
  2000::bigint, 'TEST 12b: the line total is price x quantity, snapshotted at checkout');
SELECT is((SELECT price_sen FROM public.order_items
            WHERE order_id=tests.uid('_order') AND product_id=tests.uid('_p1')),
  1000::bigint, 'TEST 12c: the unit price is snapshotted, so a later price change cannot rewrite it');

-- a later price change does not disturb the order already placed
UPDATE public.products SET price_sen = 9999 WHERE id = tests.uid('_p1');
SELECT is((SELECT line_total_sen FROM public.order_items
            WHERE order_id=tests.uid('_order') AND product_id=tests.uid('_p1')),
  2000::bigint, 'TEST 12d: repricing the product does not alter a placed order');
UPDATE public.products SET price_sen = 1000 WHERE id = tests.uid('_p1');

-- ── 13. discounts are refused while the funding policy is undefined ───────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p1'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_checkout(%L, 'ANYCODE')$$, tests.uid('_addr')),
  NULL, NULL, 'TEST 13a: a marketplace checkout carrying a voucher code is refused');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.orders WHERE discount_sen <> 0),
  0, 'TEST 13b: no order anywhere carries a discount');
-- The bridge carries the same refusal, so a discounted order cannot reach a
-- carrier even if some future caller bypasses rpc_checkout.
SELECT ok(pg_get_functiondef('internal.fn_bridge_order_to_delivery(uuid)'::regprocedure)
          LIKE '%DISCOUNT_POLICY_UNDEFINED%',
  'TEST 13c: the bridge refuses a discounted order as a second line of defence');
DELETE FROM public.cart_items ci USING public.carts c
  WHERE ci.cart_id=c.id AND c.user_id=tests.uid('aisyah');

-- ── 14/15. the payment intent, on the existing payments table ─────────────
SELECT is((SELECT count(*)::int FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  1, 'TEST 14a: checkout opens exactly one payment intent for the order');
SELECT is((SELECT amount_sen FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  'TEST 14b: the intent is for the server-computed order total');
SELECT is((SELECT method::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'COD', 'TEST 14c: COD is the only method, matching payment_methods_enabled');
SELECT is((SELECT status::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'COD_PENDING', 'TEST 14d: the intent starts unpaid -- nothing is captured at checkout');
SELECT is((SELECT payer_id FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  tests.uid('aisyah'), 'TEST 15a: the intent is against the buyer who checked out');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('_order')),
  'PENDING_PAYMENT', 'TEST 15b: the order moves off CREATED once its intent exists');

-- ── 16. a duplicate intent for the same order is not opened twice ─────────
SELECT ok((internal.fn_create_order_payment_intent(tests.uid('_order'))).id
          = (SELECT id FROM internal.payments
              WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'TEST 16a: reopening the intent returns the existing one');
SELECT is((SELECT count(*)::int FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  1, 'TEST 16b: no second claim on the same order is created');

-- ── 17/18. an uncaptured payment funds nothing and settles nothing ────────
SELECT is((SELECT count(*)::int FROM internal.ledger_transactions
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  0, 'TEST 17: an intent alone posts nothing to the ledger');
SELECT ok(EXISTS (SELECT 1 FROM public.kirim_requests
                   WHERE order_id=tests.uid('_order') AND kirim_type='PASARAN'),
  'TEST 18: the order is bridged to a delivery job so a carrier can take it');

SELECT * FROM finish();
ROLLBACK;
