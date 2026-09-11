-- ============================================================================
-- P1-D / P1-E / P1-F / P1-I regression: the whole marketplace lifecycle, from
-- a bridged order through carrier assignment, seller handover, proof-gated
-- delivery, COD capture and settlement (0027, 0028, 0029).
--
-- The money assertions are the point. A 3000 sen basket at 10% seller
-- commission, carried on a quote whose platform cut is 25% of the fee:
--
--   SELLER   = 3000 - 300                       = 2700
--   CARRIER  = fee - quote_commission - agent
--   PLATFORM = 300 + quote_commission
--   sum      = 3000 + fee                       = what the customer pays
-- ============================================================================
BEGIN;
SELECT plan(37);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p18_seller', '+60128881801', ARRAY['customer','seller']);
SELECT tests.create_user('p18_thief',  '+60128881802', ARRAY['customer']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p18_seller'),'Kedai P18',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P18',v_cat,1000,500) RETURNING id INTO v_p;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_s',v_s),('_p',v_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 10 WHERE product_id = tests.uid('_p');

SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 3 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim', id FROM public.kirim_requests WHERE order_id=tests.uid('_order')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

-- ── 19/21. a valid order becomes a delivery job with the right parties ────
SELECT is((SELECT kirim_type::text FROM public.kirim_requests WHERE id=tests.uid('_kirim')),
  'PASARAN', 'TEST 19a: the order is carried as a PASARAN kirim');
SELECT is((SELECT status::text FROM public.kirim_requests WHERE id=tests.uid('_kirim')),
  'POSTED', 'TEST 19b: the job is posted to the board for a carrier to accept');
SELECT is((SELECT requester_id FROM public.kirim_requests WHERE id=tests.uid('_kirim')),
  tests.uid('aisyah'), 'TEST 21a: the delivery job belongs to the buyer');
SELECT is((SELECT o.seller_id FROM public.orders o WHERE o.id=tests.uid('_order')),
  tests.uid('_s'), 'TEST 21b: the order belongs to the seller whose product it is');
SELECT is((SELECT total_escrow_sen FROM public.kirim_requests WHERE id=tests.uid('_kirim')),
  (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  'TEST 21c: the job carries the order total, not just the carriage fee');

-- ── 20. an order with no price cannot be bridged ─────────────────────────
DO $$
DECLARE v_o UUID;
BEGIN
  INSERT INTO public.orders (order_group_id, reference_code, buyer_id, seller_id,
    goods_subtotal_sen, delivery_fee_sen, discount_sen, commission_sen, total_sen,
    address_snapshot)
  VALUES (gen_random_uuid(), 'ORD-P18-BAD', tests.uid('aisyah'), tests.uid('_s'),
    1000, 0, 0, 100, 1000, '{}'::jsonb)
  RETURNING id INTO v_o;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_badorder', v_o)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT throws_ok(
  format($$SELECT internal.fn_bridge_order_to_delivery(%L)$$, tests.uid('_badorder')),
  NULL, NULL, 'TEST 20: an unpriced order cannot become a delivery job');

-- ── 22. carrier assignment ────────────────────────────────────────────────
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('_delivery')),
  'MATCHED', 'TEST 22a: accepting the offer matches the delivery -- no ACCEPTED state exists');
SELECT is((SELECT cod_amount_sen FROM public.deliveries WHERE id=tests.uid('_delivery')),
  (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  'TEST 22b: the carrier is told to collect the whole order, goods included');
SELECT is((SELECT count(*)::int FROM internal.payment_allocations
            WHERE order_id=tests.uid('_order')),
  3, 'TEST 22c: assignment declares the seller, carrier and platform allocations');
SELECT is((SELECT count(*)::int FROM internal.payment_allocations
            WHERE order_id=tests.uid('_order') AND status <> 'HELD'),
  0, 'TEST 22d: every allocation starts HELD -- declaring is not paying');
SELECT is((SELECT SUM(amount_sen)::bigint FROM internal.payment_allocations
            WHERE order_id=tests.uid('_order')),
  (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  'TEST 22e: the allocations sum to exactly what the customer pays');
SELECT is((SELECT count(*)::int FROM internal.ledger_transactions
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  0, 'TEST 22f: assignment moves no money');

-- ── 23. seller handover ───────────────────────────────────────────────────
SELECT throws_ok(
  format($$SELECT public.rpc_issue_handover_code(%L,'pickup')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 23a: an unauthenticated caller cannot be issued a handover code');

SELECT tests.authenticate_as('p18_thief');
SELECT throws_ok(
  format($$SELECT public.rpc_issue_handover_code(%L,'pickup')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 23b: a stranger cannot be issued the seller''s pickup code');

SELECT tests.authenticate_as('p18_seller');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_issue_handover_code(tests.uid('_delivery'),'pickup');
  PERFORM set_config('tests.p18_code', r->>'code', false);
END $$;
SELECT matches(current_setting('tests.p18_code'), '^[0-9]{6}$',
  'TEST 23c: the seller receives a six-digit handover code');

SELECT tests.authenticate_as('rahman');
SELECT is((public.rpc_verify_handover_code(
             tests.uid('_delivery'),'pickup','000000x'))->>'verified',
  'false', 'TEST 23d: a wrong code does not verify');
SELECT is((public.rpc_verify_handover_code(
             tests.uid('_delivery'),'pickup', current_setting('tests.p18_code')))->>'verified',
  'true', 'TEST 23e: the real code verifies for the carrier carrying this delivery');
SELECT tests.clear_auth();
SELECT ok((SELECT consumed_at IS NOT NULL FROM public.handover_codes
            WHERE delivery_id=tests.uid('_delivery') AND leg='pickup'
            ORDER BY created_at DESC LIMIT 1),
  'TEST 23f: a verified code is consumed and cannot be replayed');

-- ── 24. required proof of delivery is enforced ────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'GO_TO_PICKUP');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'CONFIRM_PICKUP')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 24a: pickup cannot be confirmed without pickup proof');

SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery'),'pickup','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_PICKUP');
SELECT tests.clear_auth();
SELECT is((SELECT on_hand||'/'||reserved FROM public.inventory WHERE product_id=tests.uid('_p')),
  '7/0', 'TEST 24b: custody passing turns the reservation into a sale');

SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'START_DELIVERY');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'CONFIRM_DELIVERY')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 24c: delivery cannot be confirmed without dropoff proof');

SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

-- ── 25. a delivered order is settlement-eligible, and the cash is recorded ─
SELECT is((SELECT status::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'CAPTURED', 'TEST 25a: COD collected at the door captures the payment');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'TEST 25b: a delivered, paid, undisputed order is eligible to settle');
SELECT ok((SELECT settlement_due_at IS NOT NULL FROM public.deliveries WHERE id=tests.uid('_delivery')),
  'TEST 25c: the 48-hour auto-release clock is set on delivery');
SELECT is((SELECT cod_held_sen FROM public.carriers WHERE id=tests.uid('_carrier')),
  (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  'TEST 25d: the carrier is recorded as holding the customer''s cash');

-- ── 26. only this delivery's customer may confirm receipt ────────────────
SELECT tests.authenticate_as('p18_thief');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'CONFIRM_RECEIPT')$$, tests.uid('_delivery')),
  NULL, NULL,
  'TEST 26a: holding the customer role does not let a stranger confirm someone else''s delivery');

SELECT tests.authenticate_as('aisyah');
SELECT is((public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_RECEIPT'))->>'status',
  'COMPLETED', 'TEST 26b: the buyer confirming receipt completes the delivery');
SELECT tests.clear_auth();

-- ── 27/28/29/30. the money lands where the allocation said it would ──────
SELECT is(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  2700::bigint, 'TEST 27: the seller is credited goods minus seller commission');
SELECT is(internal.fn_account_balance_sen('CARRIER_PAYABLE:'||tests.uid('_carrier')::text),
  (SELECT amount_sen FROM internal.payment_allocations
    WHERE order_id=tests.uid('_order') AND allocation_type='CARRIER'),
  'TEST 28: the carrier is credited exactly their declared delivery earning');
SELECT is(internal.fn_account_balance_sen('PLATFORM_COMMISSION'),
  (SELECT amount_sen FROM internal.payment_allocations
    WHERE order_id=tests.uid('_order') AND allocation_type='PLATFORM'),
  'TEST 29: KasihKirim is credited exactly its declared commission');
SELECT is(internal.fn_account_balance_sen('ESCROW_HELD_GOODS')
        + internal.fn_account_balance_sen('ESCROW_HELD_DELIVERY'),
  0::bigint, 'TEST 30a: escrow is emptied -- everything funded at capture is released');
SELECT is((SELECT count(*)::int FROM internal.payment_allocations
            WHERE order_id=tests.uid('_order') AND status <> 'SETTLED'),
  0, 'TEST 30b: every allocation is marked settled');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('_order')),
  'SETTLED', 'TEST 30c: the order reaches SETTLED');

-- ── 31. settling twice is a no-op ────────────────────────────────────────
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')),
  'ALREADY_SETTLED', 'TEST 31a: a settled delivery reports itself already settled');
SELECT lives_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('_delivery')),
  'TEST 31b: settling again is accepted rather than raising');
SELECT is(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  2700::bigint, 'TEST 31c: the second settlement credits nothing further');

-- ── earnings come from the ledger, not from a second wallet ──────────────
SELECT tests.authenticate_as('p18_seller');
SELECT is((public.rpc_my_earnings()->>'seller_available_sen')::bigint,
  2700::bigint, 'TEST 31d: seller earnings are read from the ledger balance');

SELECT * FROM finish();
ROLLBACK;
