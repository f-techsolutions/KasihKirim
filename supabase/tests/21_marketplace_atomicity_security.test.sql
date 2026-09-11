-- ============================================================================
-- P1-J / P1-K regression: the failure paths and the security surface.
--
-- "The system must never create an impossible financial state." The cases
-- below are the ones that would produce one: stock reserved against an order
-- that dies, an order fulfilled without payment, and any authenticated user
-- reaching past the RPCs to write the numbers directly.
-- ============================================================================
BEGIN;
SELECT plan(24);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p21_seller', '+60128882101', ARRAY['customer','seller']);
SELECT tests.create_user('p21_other',  '+60128882102', ARRAY['customer']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p21_seller'),'Kedai P21',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P21',v_cat,1000,500) RETURNING id INTO v_p;
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
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim', id FROM public.kirim_requests WHERE order_id=tests.uid('_order')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

-- ── J1/J2. checkout succeeds and stock is held, not yet sold ─────────────
SELECT is((SELECT on_hand||'/'||reserved FROM public.inventory WHERE product_id=tests.uid('_p')),
  '10/3', 'TEST J1: a placed order holds stock without yet consuming it');
SELECT is((SELECT count(*)::int FROM public.carts c JOIN public.cart_items ci ON ci.cart_id=c.id
            WHERE c.user_id=tests.uid('aisyah')),
  0, 'TEST J12: the cart that was checked out is cleared, so it cannot be checked out twice');

-- ── J3/J4. no payment means no fulfilment and no money ───────────────────
SELECT is((SELECT status::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'COD_PENDING', 'TEST J3a: the payment is not captured merely by placing the order');
SELECT is((SELECT count(*)::int FROM internal.ledger_entries e
            JOIN internal.ledger_transactions t ON t.id=e.transaction_id
           WHERE t.reference_id=tests.uid('_order')),
  0, 'TEST J3b: nothing is posted to the ledger before the money exists');
SELECT is(internal.fn_settlement_blocked_reason(
            (SELECT id FROM public.deliveries d
              WHERE d.kirim_id=tests.uid('_kirim') LIMIT 1)),
  'DELIVERY_NOT_FOUND', 'TEST J4: an unassigned order has no delivery to settle');

-- ── J5/J6/J7. the order is cancelled before it is carried ───────────────
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CANCEL');
SELECT tests.clear_auth();

SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('_delivery')),
  'CANCELLED', 'TEST J5: a cancelled delivery reaches CANCELLED');
SELECT is((SELECT on_hand||'/'||reserved FROM public.inventory WHERE product_id=tests.uid('_p')),
  '10/0', 'TEST J6: cancelling gives the reserved stock back and sells none of it');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('_order')),
  'CANCELLED', 'TEST J7a: the order follows the delivery to CANCELLED');
SELECT is((SELECT count(*)::int FROM internal.payment_allocations
            WHERE order_id=tests.uid('_order') AND status='HELD'),
  0, 'TEST J7b: the allocations are voided, so nothing is left claimable');
SELECT is((SELECT count(*)::int FROM internal.ledger_entries e
            JOIN internal.ledger_transactions t ON t.id=e.transaction_id
           WHERE t.reference_id=tests.uid('_order')),
  0, 'TEST J8: a cancelled order moves no money in either direction');

-- releasing twice does not hand back stock that was never held
SELECT lives_ok(
  format($$SELECT internal.fn_release_order_stock(%L)$$, tests.uid('_order')),
  'TEST J9a: releasing an already-released order is accepted');
SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p')),
  0, 'TEST J9b: and returns nothing a second time');

-- ── K. the financial surface is not reachable from a signed-in session ──
SELECT tests.authenticate_as('p21_other');

SELECT throws_ok(
  $$INSERT INTO internal.payment_allocations
      (payment_id, order_id, allocation_type, payee_type, payee_id, amount_sen)
    VALUES (gen_random_uuid(), gen_random_uuid(), 'SELLER', 'seller', gen_random_uuid(), 999999)$$,
  NULL, NULL, 'TEST K3: a signed-in user cannot write a payment allocation');

SELECT throws_ok(
  $$UPDATE internal.payment_allocations SET amount_sen = 1$$,
  NULL, NULL, 'TEST K4: nor set their own payout amount by editing one');

SELECT throws_ok(
  $$INSERT INTO internal.ledger_entries (transaction_id, account_id, direction, amount_sen)
    VALUES (gen_random_uuid(), gen_random_uuid(), 'CREDIT', 100000)$$,
  NULL, NULL, 'TEST K5: nor post to the ledger directly');

SELECT throws_ok(
  $$UPDATE internal.payments SET status = 'CAPTURED'$$,
  NULL, NULL, 'TEST K6: nor mark a payment as held');

SELECT throws_ok(
  $$INSERT INTO internal.payouts (payee_type, payee_id, amount_sen, bank_account_id)
    VALUES ('seller', gen_random_uuid(), 500000, gen_random_uuid())$$,
  NULL, NULL, 'TEST K7: nor request a payout for themselves');

-- K8/K11: which mechanism stops this write is genuinely environment-
-- dependent and not something a test should assume. Confirmed by running
-- this suite against two real, differently-provisioned Postgres images in
-- CI: one grants `authenticated` no UPDATE on these two tables at all (the
-- write is refused at the privilege check, and raises); the other grants it
-- by platform default, so RLS -- which has no UPDATE policy on either table
-- -- is what denies every row, silently, without raising. 0010's header
-- describes the first; a newer Supabase-provisioned Postgres can do the
-- second. Both are the same guarantee wearing a different mechanism, so the
-- test asserts the guarantee -- the value is unchanged -- and tolerates
-- either mechanism getting there, rather than asserting which one a given
-- environment happens to use.
DO $$ BEGIN
  UPDATE public.sellers SET commission_bps = 0;
EXCEPTION WHEN OTHERS THEN NULL; END $$;
SELECT is((SELECT commission_bps FROM public.sellers WHERE id=tests.uid('_s')),
  1000, 'TEST K8: a signed-in user cannot set the commission rate, by grant or by RLS');

-- deliveries.status: BR-904 makes fn_delivery_transition its only writer.
-- Unlike sellers/inventory, deliveries has an explicit REVOKE (0001, 0010)
-- rather than merely never having been granted, so this one genuinely does
-- raise in every environment.
SELECT throws_ok(
  format($$UPDATE public.deliveries SET status='DELIVERED' WHERE id=%L$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST K10: a delivery cannot be marked delivered by direct table update');

DO $$ BEGIN
  UPDATE public.inventory SET on_hand = 100000;
EXCEPTION WHEN OTHERS THEN NULL; END $$;
-- Read it back unprivileged: inventory_own scopes SELECT to the owning
-- seller, so the attacker cannot even see the row they tried to rewrite.
SELECT tests.clear_auth();
SELECT is((SELECT on_hand FROM public.inventory WHERE product_id=tests.uid('_p')),
  10, 'TEST K11: stock cannot be granted by writing to inventory, by grant or by RLS');
SELECT tests.authenticate_as('p21_other');

SELECT throws_ok(
  format($$INSERT INTO public.disputes
             (delivery_id, raised_by, category, description, sla_due_at)
           VALUES (%L, %L, 'damaged', 'direct insert', now() + interval '3 days')$$,
          tests.uid('_delivery'), tests.uid('p21_other')),
  NULL, NULL, 'TEST K12: nor can a dispute be inserted directly, bypassing ownership checks');

SELECT throws_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST K13: settlement is not callable from a signed-in session');

SELECT throws_ok(
  format($$SELECT internal.fn_sweep_settlements()$$),
  NULL, NULL, 'TEST K14: neither is the auto-release sweep');

SELECT throws_ok(
  $$SELECT * FROM public.handover_codes$$,
  NULL, NULL, 'TEST K15: handover codes are readable by nobody, hashed or not');

SELECT * FROM finish();
ROLLBACK;
