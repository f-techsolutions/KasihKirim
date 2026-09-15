-- ============================================================================
-- P1-H / P1-I regression: customer-raised disputes and refund-as-reversal
-- (0028_handover_and_dispute.sql, 0029_settlement_sweep_and_earnings.sql).
--
-- public.disputes has had a SELECT policy since 0003 and no way to insert a
-- row. The DELIVERED --OPEN_DISPUTE--> DISPUTED transition has been seeded all
-- along, but firing it moved the delivery without creating a dispute, and
-- fn_settlement_blocked_reason blocks on the ROW -- so the money would have
-- been released anyway.
-- ============================================================================
BEGIN;
SELECT plan(28);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p19_seller',  '+60128881901', ARRAY['customer','seller']);
SELECT tests.create_user('p19_stranger','+60128881902', ARRAY['customer']);

-- ── a delivered, captured, undisputed marketplace order ───────────────────
DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p19_seller'),'Kedai P19',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P19',v_cat,1000,500) RETURNING id INTO v_p;
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

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'GO_TO_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'setup: the order is eligible to settle before anybody disputes it');

-- ── 38. a stranger cannot dispute somebody else's order ──────────────────
SELECT tests.authenticate_as('p19_stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_open_dispute(%L,'damaged','Barang rosak sampai rumah saya')$$,
         tests.uid('_delivery')),
  NULL, NULL, 'TEST 38a: a customer cannot open a dispute on another customer''s order');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  0, 'TEST 38b: the refused attempt creates no dispute row');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'TEST 38c: a stranger cannot freeze somebody else''s settlement');

-- ── validation before anything is written ────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_open_dispute(%L,'alien_abduction','Barang hilang di angkasa')$$,
         tests.uid('_delivery')),
  NULL, NULL, 'TEST 37a: an unknown dispute category is refused');
SELECT throws_ok(
  format($$SELECT public.rpc_open_dispute(%L,'damaged','rosak')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 37b: a description too short to act on is refused');

-- ── 37. the buyer raises a dispute on their own order ────────────────────
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_open_dispute(tests.uid('_delivery'),'damaged',
        'Sayur sampai dalam keadaan rosak dan tidak boleh dimakan');
  INSERT INTO tests.handles(handle,user_id) VALUES ('_dispute',(r->>'dispute_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT status::text FROM public.disputes WHERE id=tests.uid('_dispute')),
  'OPEN', 'TEST 37c: the dispute is created open');
SELECT is((SELECT raised_by FROM public.disputes WHERE id=tests.uid('_dispute')),
  tests.uid('aisyah'), 'TEST 37d: the dispute is attributed to the buyer who raised it');
SELECT is((SELECT order_id FROM public.disputes WHERE id=tests.uid('_dispute')),
  tests.uid('_order'), 'TEST 37e: the dispute is linked to the order, not just the delivery');
SELECT is((SELECT against_id FROM public.disputes WHERE id=tests.uid('_dispute')),
  tests.uid('p19_seller'), 'TEST 37f: a marketplace dispute is routed against the seller');
SELECT is((SELECT refund_sen FROM public.disputes WHERE id=tests.uid('_dispute')),
  0::bigint, 'TEST 37g: opening a dispute refunds nothing -- no amount is taken from the caller');
SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('_delivery')),
  'DISPUTED', 'TEST 37h: the delivery moves to DISPUTED through the existing state machine');
SELECT ok(EXISTS (SELECT 1 FROM audit.audit_logs
                   WHERE action='DISPUTE_OPENED' AND entity_id=tests.uid('_dispute')),
  'TEST 37i: the dispute is written to the audit trail');

-- ── 32/40. a dispute blocks settlement ───────────────────────────────────
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')),
  'ESCROW_HELD_BY_DISPUTE', 'TEST 40a: an open dispute blocks settlement');
SELECT throws_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 40b: attempting to settle a disputed delivery is refused');
SELECT is(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  0::bigint, 'TEST 32: no money reaches the seller while the claim is open');

-- ── 39. a duplicate active dispute is refused ────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_open_dispute(%L,'wrong_item','Barang yang dihantar bukan pesanan saya')$$,
         tests.uid('_delivery')),
  NULL, NULL, 'TEST 39a: a second open dispute on the same delivery is refused');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  1, 'TEST 39b: exactly one dispute exists');

-- ── 47/48/49. refund is a ledger reversal ────────────────────────────────
SELECT tests.authenticate_as('admin');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_admin_resolve_dispute(
         tests.uid('_dispute'),'RESOLVED_REFUND_FULL','Barang rosak disahkan',
         (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')));
  PERFORM set_config('tests.p19_refund_txn', COALESCE(r->>'refund_txn',''), false);
END $$;
SELECT tests.clear_auth();

SELECT ok(current_setting('tests.p19_refund_txn') <> '',
  'TEST 47a: resolving with a refund actually posts a ledger transaction');
SELECT ok((SELECT reverses_id IS NOT NULL FROM internal.ledger_transactions
            WHERE id = current_setting('tests.p19_refund_txn')::uuid),
  'TEST 47b: the refund is linked to the capture it reverses');
SELECT is((SELECT t.kind FROM internal.ledger_transactions t
            WHERE t.id = current_setting('tests.p19_refund_txn')::uuid),
  'REFUND', 'TEST 47c: it is recorded as a refund, not an unexplained movement');

SELECT is(internal.fn_account_balance_sen('ESCROW_HELD_GOODS')
        + internal.fn_account_balance_sen('ESCROW_HELD_DELIVERY'),
  0::bigint, 'TEST 48a: capture and reversal cancel out exactly, on every escrow account');
SELECT is(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  0::bigint, 'TEST 48b: nothing is clawed back from the seller, because nothing was paid');
SELECT is((SELECT status::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'REFUNDED', 'TEST 48c: the payment ends REFUNDED');

-- the reversal adds entries; it never edits the ones already written
SELECT is((SELECT count(*)::int FROM internal.ledger_entries e
            JOIN internal.ledger_transactions t ON t.id=e.transaction_id
           WHERE t.idempotency_key LIKE 'capture:%'),
  (SELECT count(*)::int FROM internal.ledger_entries e
     JOIN internal.ledger_transactions t ON t.id=e.transaction_id
    WHERE t.id = current_setting('tests.p19_refund_txn')::uuid),
  'TEST 49a: the reversal mirrors the capture entry for entry');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')),
  'PAYMENT_NOT_HELD',
  'TEST 49b: a refunded order cannot then also be settled to the seller and carrier');

-- ── 50. the refund is idempotent ─────────────────────────────────────────
SELECT is(internal.fn_refund_order(
            tests.uid('_order'),
            (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
            'replay', NULL),
  current_setting('tests.p19_refund_txn')::uuid,
  'TEST 50a: refunding again returns the same transaction');
SELECT is(internal.fn_account_balance_sen('ESCROW_HELD_GOODS'),
  0::bigint, 'TEST 50b: the replay posts nothing further');

SELECT * FROM finish();
ROLLBACK;
