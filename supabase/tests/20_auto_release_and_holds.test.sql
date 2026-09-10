-- ============================================================================
-- P1-G / P1-J / P1-K regression: the auto-release sweep, risk holds, the
-- eligibility gates, and the failure paths (0029, 0027, 0025).
--
-- The central case is TEST 42/44. seed.sql used to schedule
--
--   SELECT internal.fn_settle_delivery(id) FROM public.deliveries
--    WHERE status='DELIVERED' AND settlement_due_at < now()
--
-- and 0024 gave fn_settle_delivery eligibility rules that RAISE. A raise
-- inside a set-returning SELECT aborts the whole statement, so a single
-- ineligible marketplace order would have silently stopped every other
-- delivery in the batch from settling, every ten minutes. The sweep below
-- has four due deliveries, three of them ineligible for three different
-- reasons, and must still settle the fourth.
-- ============================================================================
BEGIN;
SELECT plan(31);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p20_seller', '+60128882001', ARRAY['customer','seller']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p20_seller'),'Kedai P20',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P20',v_cat,1000,500) RETURNING id INTO v_p;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_s',v_s),('_p',v_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 40 WHERE product_id = tests.uid('_p');

-- Drives one order all the way to DELIVERED and records its handles. Written
-- as a helper because this file needs four of them, differing only in what is
-- done to them afterwards.
CREATE FUNCTION tests.p20_deliver(p_tag TEXT) RETURNS VOID
LANGUAGE plpgsql AS $fn$
DECLARE r JSONB; v_order UUID; v_kirim UUID; v_delivery UUID;
BEGIN
  PERFORM tests.authenticate_as('aisyah');
  INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
  INSERT INTO public.cart_items (cart_id,product_id,quantity)
    SELECT c.id, tests.uid('_p'), 3 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
  r := public.rpc_checkout(tests.uid('_addr'));
  v_order := (r->'orders'->0->>'order_id')::uuid;

  PERFORM tests.clear_auth();
  SELECT id INTO v_kirim FROM public.kirim_requests WHERE order_id = v_order;

  PERFORM tests.authenticate_as('rahman');
  r := public.rpc_accept_offer(tests.uid('_trip'), v_kirim);
  v_delivery := (r->>'delivery_id')::uuid;

  PERFORM tests.clear_auth();
  INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
  VALUES (v_delivery,'pickup','QR','STRONG',now()),
         (v_delivery,'dropoff','QR','STRONG',now());

  PERFORM tests.authenticate_as('rahman');
  PERFORM public.rpc_delivery_transition(v_delivery,'GO_TO_PICKUP');
  PERFORM public.rpc_delivery_transition(v_delivery,'CONFIRM_PICKUP');
  PERFORM public.rpc_delivery_transition(v_delivery,'DEPART');
  PERFORM public.rpc_delivery_transition(v_delivery,'START_DELIVERY');
  PERFORM public.rpc_delivery_transition(v_delivery,'CONFIRM_DELIVERY');
  PERFORM tests.clear_auth();

  INSERT INTO tests.handles(handle,user_id) VALUES
    (p_tag||'_order', v_order), (p_tag||'_kirim', v_kirim), (p_tag||'_delivery', v_delivery)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $fn$;

SELECT tests.p20_deliver('A');   -- eligible, will be past due
SELECT tests.p20_deliver('B');   -- disputed
SELECT tests.p20_deliver('C');   -- risk hold
SELECT tests.p20_deliver('D');   -- eligible but not yet due
SELECT tests.p20_deliver('E');   -- past due, but its allocation does not add up

-- ── 41. before the window closes, nothing is auto-released ───────────────
SELECT cmp_ok((SELECT settlement_due_at FROM public.deliveries WHERE id=tests.uid('A_delivery')),
  '>', now(), 'TEST 41a: the settlement clock starts in the future, 48h out');
SELECT is((internal.fn_sweep_settlements()->>'examined')::int, 0,
  'TEST 41b: a sweep before the window examines nothing');
SELECT is(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  0::bigint, 'TEST 41c: no seller is credited before the window closes');

-- ── age A, B and C past the window; leave D inside it ───────────────────
UPDATE public.deliveries SET settlement_due_at = now() - interval '1 hour'
 WHERE id IN (tests.uid('A_delivery'), tests.uid('B_delivery'),
              tests.uid('C_delivery'), tests.uid('E_delivery'));

-- E: corrupt the allocation so the sweep meets a row it must refuse for a
-- reason unrelated to disputes or risk.
UPDATE internal.payment_allocations SET amount_sen = amount_sen + 7
 WHERE order_id = tests.uid('E_order') AND allocation_type = 'PLATFORM';

-- ── 43. an open dispute on B ─────────────────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT public.rpc_open_dispute(tests.uid('B_delivery'),'not_as_described',
  'Sayur yang sampai tidak sama dengan gambar dalam senarai') IS NOT NULL AS opened \gset
SELECT tests.clear_auth();
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('B_delivery')),
  'ESCROW_HELD_BY_DISPUTE', 'TEST 43a: the disputed delivery reports itself blocked');

-- ── 33/44. a risk hold on C ──────────────────────────────────────────────
SELECT ok(internal.fn_raise_risk_hold('order', tests.uid('C_order'),
            'suspected_collusion', 5, '{"note":"same device"}'::jsonb) IS NOT NULL,
  'TEST 33a: a risk signal can be raised against an order');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('C_delivery')),
  'RISK_HOLD', 'TEST 33b: a live risk hold blocks settlement');
SELECT throws_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('C_delivery')),
  NULL, NULL, 'TEST 33c: settling a risk-held delivery is refused outright');

-- a risk signal that does not claim to hold settlement changes nothing
SELECT tests.clear_auth();
SELECT public.rpc_risk_signal('order', tests.uid('A_order'), 'velocity', 3);
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('A_delivery')), NULL,
  'TEST 33d: an ordinary risk signal does not freeze money -- holding is opt-in');

-- ── 42/44/45. ONE SWEEP: three ineligible rows must not stall the fourth ─
DO $$
DECLARE r JSONB;
BEGIN
  r := internal.fn_sweep_settlements();
  PERFORM set_config('tests.p20_sweep', r::text, false);
END $$;

-- B never enters the sweep at all: opening a dispute moved it to DISPUTED,
-- and the sweep only considers DELIVERED. That is a second, independent
-- guard on the same money.
SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('B_delivery')),
  'DISPUTED', 'TEST 43c: a disputed delivery leaves DELIVERED, so the sweep never sees it');
SELECT is((current_setting('tests.p20_sweep')::jsonb->>'examined')::int, 3,
  'TEST 42a: the sweep examines the three still-DELIVERED rows past their window');
SELECT is((current_setting('tests.p20_sweep')::jsonb->>'settled')::int, 1,
  'TEST 42b: the one eligible delivery is settled');
SELECT is((current_setting('tests.p20_sweep')::jsonb->>'blocked')::int, 2,
  'TEST 42c: the risk-held and mis-allocated deliveries are skipped, not attempted');
SELECT is((current_setting('tests.p20_sweep')::jsonb->'reasons'->>'ALLOCATION_SUM_MISMATCH')::int,
  1, 'TEST 42h: the sweep names why each row was skipped');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('E_order')),
  'FULFILLED', 'TEST 42i: a row the sweep refused does not stop the row it accepted');
SELECT is((current_setting('tests.p20_sweep')::jsonb->>'failed')::int, 0,
  'TEST 42d: nothing raises out of the sweep');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('A_order')),
  'SETTLED', 'TEST 42e: the eligible order reaches SETTLED through auto-release');
SELECT cmp_ok(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  '>', 0::bigint, 'TEST 42f: the seller is credited by the sweep, with no customer action');

SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('B_order')),
  'FULFILLED', 'TEST 43b: the disputed order is not settled');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('C_order')),
  'FULFILLED', 'TEST 44a: the risk-held order is not settled');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('D_order')),
  'FULFILLED', 'TEST 44b: the order still inside its window is left alone');

SELECT ok(EXISTS (SELECT 1 FROM internal.job_runs
                   WHERE job_name='settle_delivered' AND outcome='OK'),
  'TEST 42g: the sweep records its own run, so a stalled batch is visible');

-- ── 45. a second sweep changes nothing ───────────────────────────────────
DO $$
DECLARE r JSONB;
BEGIN
  PERFORM set_config('tests.p20_before',
    internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text)::text, false);
  r := internal.fn_sweep_settlements();
  PERFORM set_config('tests.p20_sweep2', r::text, false);
END $$;
SELECT is((current_setting('tests.p20_sweep2')::jsonb->>'settled')::int, 0,
  'TEST 45a: the second sweep settles nothing');
SELECT is((current_setting('tests.p20_sweep2')::jsonb->>'blocked')::int, 2,
  'TEST 45b: the same two rows are refused again, for the same reasons');
SELECT is(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  current_setting('tests.p20_before')::bigint,
  'TEST 45c: no balance moves on the repeat run');

-- ── 34/35/36. the remaining eligibility gates ────────────────────────────
-- unpaid: rewind D's payment to the state it had before the doorstep
UPDATE internal.payments SET status='COD_PENDING',
       status_precedence=internal.fn_status_precedence('COD_PENDING')
 WHERE reference_type='order' AND reference_id=tests.uid('D_order');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('D_delivery')),
  'PAYMENT_NOT_HELD', 'TEST 34: an unpaid order cannot settle');
UPDATE internal.payments SET status='CAPTURED',
       status_precedence=internal.fn_status_precedence('CAPTURED')
 WHERE reference_type='order' AND reference_id=tests.uid('D_order');

DELETE FROM public.proofs WHERE delivery_id=tests.uid('D_delivery') AND leg='dropoff';
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('D_delivery')),
  'PROOF_MISSING', 'TEST 35: an order with no proof of delivery cannot settle');
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('D_delivery'),'dropoff','QR','STRONG',now());

UPDATE internal.payment_allocations SET amount_sen = amount_sen + 1
 WHERE order_id=tests.uid('D_order') AND allocation_type='SELLER';
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('D_delivery')),
  'ALLOCATION_SUM_MISMATCH',
  'TEST 36a: an allocation that does not add up to the payment cannot settle');
UPDATE internal.payment_allocations SET amount_sen = amount_sen - 1
 WHERE order_id=tests.uid('D_order') AND allocation_type='SELLER';

DELETE FROM internal.payment_allocations WHERE order_id=tests.uid('D_order');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('D_delivery')),
  'ALLOCATION_MISSING', 'TEST 36b: an order with no allocation cannot settle');

-- ── 46/K. the ledger stays the only source of truth, and stays unreachable ─
SELECT is((SELECT COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen
                                    ELSE -amount_sen END),0)::bigint
             FROM internal.ledger_entries),
  0::bigint, 'TEST 46: every ledger transaction balances -- debits equal credits');

SELECT is((SELECT count(*)::int FROM information_schema.role_table_grants
            WHERE table_schema='internal' AND grantee IN ('anon','authenticated')),
  0, 'TEST K1: no internal table is granted to anon or authenticated');
SELECT is((SELECT count(*)::int FROM information_schema.routine_privileges
            WHERE specific_schema='internal' AND grantee IN ('anon','authenticated','PUBLIC')
              AND routine_name IN ('fn_sweep_settlements','fn_refund_order',
                                   'fn_allocate_order_payment','fn_capture_order_cod',
                                   'fn_adjust_inventory','fn_settlement_blocked_reason')),
  0, 'TEST K2: no P1 financial function is callable by a signed-in user');

SELECT * FROM finish();
ROLLBACK;
