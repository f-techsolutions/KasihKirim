-- ============================================================================
-- 0024_order_settlement_allocations.sql — marketplace settlement correctness.
--
-- Regression coverage for the P0 defect this migration fixes: settling an
-- order-linked delivery through Kirim's budget-minus-actual arithmetic
-- refunded the buyer the whole goods value (kirim_requests.actual_goods_sen
-- is never set for a marketplace order, so v_refund became the entire
-- goods_budget) and credited the seller nothing, because no SELLER_PAYABLE
-- leg existed at all.
--
-- Every money assertion below is in sen, and the ledger is checked as the
-- authority -- never a convenience column.
-- ============================================================================
BEGIN;
SELECT plan(40);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('penjual',  '+60128881010', ARRAY['customer','seller']);
SELECT tests.create_user('penjual2', '+60128881011', ARRAY['customer','seller']);
SELECT tests.create_user('penjual3', '+60128881013', ARRAY['customer','seller']);
SELECT tests.create_user('pembeli',  '+60128881012', ARRAY['customer']);

-- ── Scenario builder ────────────────────────────────────────────────────────
-- Creates a complete, realistic marketplace scenario: approved seller, order,
-- PASARAN kirim carrying order_id, delivery at DELIVERED, dropoff proof, and
-- a captured payment. Registers handles as <tag>_order / <tag>_delivery /
-- <tag>_payment / <tag>_seller so each case can work on its own isolated set.
CREATE OR REPLACE FUNCTION tests.mk_order_scenario(
  p_tag            TEXT,
  p_seller_handle  TEXT,
  p_goods_sen      BIGINT,
  p_order_comm_sen BIGINT,
  p_delivery_sen   BIGINT,
  p_quote_comm_sen BIGINT,
  p_payment_sen    BIGINT,
  p_with_proof     BOOLEAN DEFAULT true,
  p_pay_status     TEXT    DEFAULT 'SUCCEEDED',
  -- Goods value carried on the delivery quote. Zero matches what
  -- fn_quote_kirim produces today for a non-BELI type; a non-zero value is
  -- what any marketplace quote that prices goods would carry, and is the
  -- exact input that made the old settlement refund the buyer.
  p_quote_goods_sen BIGINT DEFAULT 0)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
  v_seller UUID; v_order UUID; v_quote UUID; v_kirim UUID;
  v_delivery UUID; v_payment UUID; v_origin UUID; v_dest UUID; v_cat UUID;
BEGIN
  SELECT origin_node_id, dest_node_id INTO v_origin, v_dest
    FROM public.kirim_requests WHERE id = tests.uid('_kirim');
  SELECT id INTO v_cat FROM ref.categories LIMIT 1;

  INSERT INTO public.sellers (user_id, business_name, community_id, status, commission_bps)
  SELECT tests.uid(p_seller_handle), 'Kedai '||p_tag,
         (SELECT community_id FROM public.addresses WHERE id = tests.uid('_addr')),
         'APPROVED', 1000
  ON CONFLICT (user_id) DO UPDATE SET status='APPROVED'
  RETURNING id INTO v_seller;

  INSERT INTO public.orders (order_group_id, reference_code, buyer_id, seller_id,
    goods_subtotal_sen, delivery_fee_sen, discount_sen, commission_sen, total_sen,
    address_snapshot)
  VALUES (gen_random_uuid(), 'ORD-TEST-'||p_tag, tests.uid('pembeli'), v_seller,
    p_goods_sen, p_delivery_sen, 0, p_order_comm_sen, p_goods_sen + p_delivery_sen,
    '{"line1":"test"}'::jsonb)
  RETURNING id INTO v_order;

  INSERT INTO internal.quotes (subject_type, requester_id, input_snapshot, breakdown,
    goods_budget_sen, delivery_fee_sen, commission_sen, total_sen,
    pricing_rule_version, expires_at)
  VALUES ('kirim', tests.uid('pembeli'), '{}'::jsonb, '{}'::jsonb,
    p_quote_goods_sen, p_delivery_sen, p_quote_comm_sen,
    p_quote_goods_sen + p_delivery_sen,
    (SELECT version FROM internal.pricing_rules ORDER BY version DESC LIMIT 1),
    now() + interval '1 day')
  RETURNING id INTO v_quote;

  INSERT INTO public.kirim_requests (reference_code, requester_id, kirim_type, status,
    item_description, category_id, est_weight_grams, dest_address_id,
    origin_node_id, dest_node_id, quote_id, order_id, payment_method,
    delivery_fee_sen, commission_sen, total_escrow_sen)
  VALUES ('KK-TEST-'||p_tag, tests.uid('pembeli'), 'PASARAN', 'DELIVERED',
    'Pesanan ujian', v_cat, 1000, tests.uid('_addr'),
    v_origin, v_dest, v_quote, v_order, 'FPX',
    p_delivery_sen, p_quote_comm_sen, p_payment_sen)
  RETURNING id INTO v_kirim;

  INSERT INTO public.deliveries (kirim_id, carrier_id, status, delivered_at)
  VALUES (v_kirim, tests.uid('_carrier'), 'DELIVERED', now())
  RETURNING id INTO v_delivery;

  IF p_with_proof THEN
    INSERT INTO public.proofs (delivery_id, leg, method, quality, photo_path, captured_at)
    VALUES (v_delivery, 'dropoff', 'PHOTO', 'STRONG', 'pod/'||p_tag||'.jpg', now());
  END IF;

  INSERT INTO internal.payments (reference_type, reference_id, payer_id, provider,
    provider_ref, method, amount_sen, status, idempotency_key)
  VALUES ('order', v_order, tests.uid('pembeli'), 'sandbox',
    'ref-'||p_tag, 'FPX', p_payment_sen, p_pay_status::ref.payment_status, 'idem-'||p_tag)
  RETURNING id INTO v_payment;

  INSERT INTO tests.handles (handle, user_id) VALUES
    (p_tag||'_order', v_order), (p_tag||'_delivery', v_delivery),
    (p_tag||'_payment', v_payment), (p_tag||'_seller', v_seller)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

-- Sums CREDIT minus DEBIT for one account code, straight from ledger entries.
CREATE OR REPLACE FUNCTION tests.acct_balance(p_code TEXT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT COALESCE(SUM(CASE WHEN e.direction='CREDIT' THEN e.amount_sen
                           ELSE -e.amount_sen END), 0)::bigint
    FROM internal.ledger_entries e
    JOIN internal.ledger_accounts a ON a.id = e.account_id
   WHERE a.account_code = p_code;
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 1 — the approved commercial model, end to end.
--   customer pays RM130 = seller RM100 + carrier RM20 + KasihKirim RM10
-- ════════════════════════════════════════════════════════════════════════════
SELECT tests.mk_order_scenario('t1','penjual', 11000, 1000, 2000, 0, 13000);

SELECT is((SELECT actual_goods_sen FROM public.kirim_requests
            WHERE order_id = tests.uid('t1_order')), NULL::bigint,
  'precondition: a marketplace order never sets actual_goods_sen');

SELECT lives_ok(
  format($$SELECT internal.fn_allocate_order_payment(%L,%L)$$,
         tests.uid('t1_payment'), tests.uid('t1_delivery')),
  'allocations are derived server-side from the order and the delivery quote');

SELECT is((SELECT SUM(amount_sen)::bigint FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment')), 13000::bigint,
  'INVARIANT: allocations sum exactly to the payment amount');

SELECT is((SELECT amount_sen FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment') AND allocation_type='SELLER'),
  10000::bigint, 'seller is allocated the product price net of commission');

SELECT is((SELECT amount_sen FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment') AND allocation_type='CARRIER'),
  2000::bigint, 'carrier is allocated the delivery fee');

SELECT is((SELECT amount_sen FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment') AND allocation_type='PLATFORM'),
  1000::bigint, 'KasihKirim is allocated the commission');

SELECT is(internal.fn_settlement_blocked_reason(tests.uid('t1_delivery')), NULL,
  'a paid, delivered, proven, undisputed order is eligible to settle');

SELECT lives_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('t1_delivery')),
  'settlement runs');

SELECT is(tests.acct_balance('SELLER_PAYABLE:'||tests.uid('t1_seller')::text),
  10000::bigint, 'THE FIX: the seller is credited RM100, not nothing');

SELECT is(tests.acct_balance('CARRIER_PAYABLE:'||tests.uid('_carrier')::text),
  2000::bigint, 'the carrier is credited RM20');

SELECT is(tests.acct_balance('PLATFORM_COMMISSION'), 1000::bigint,
  'KasihKirim recognises RM10 commission');

SELECT is(tests.acct_balance('REQUESTER_REFUND:'||tests.uid('pembeli')::text), 0::bigint,
  'THE DEFECT: the buyer is NOT refunded the goods value');

-- ── Double-entry and escrow drain ───────────────────────────────────────────
SELECT is(
  (SELECT SUM(CASE WHEN e.direction='DEBIT' THEN e.amount_sen ELSE -e.amount_sen END)::bigint
     FROM internal.ledger_entries e
     JOIN internal.ledger_transactions t ON t.id = e.transaction_id
    WHERE t.idempotency_key = 'settle:'||tests.uid('t1_delivery')::text),
  0::bigint, 'INVARIANT: the settlement transaction balances (debits = credits)');

SELECT is((SELECT status FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment') AND allocation_type='SELLER'),
  'SETTLED', 'the seller allocation is marked settled');

SELECT is((SELECT status::text FROM internal.payments WHERE id = tests.uid('t1_payment')),
  'SETTLED', 'the payment reaches SETTLED');

SELECT is((SELECT status::text FROM public.orders WHERE id = tests.uid('t1_order')),
  'SETTLED', 'the order reaches SETTLED');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 4 / 8 — settling again must not pay anyone twice.
-- ════════════════════════════════════════════════════════════════════════════
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('t1_delivery')), 'ALREADY_SETTLED',
  'a settled delivery reports ALREADY_SETTLED');

SELECT lives_ok(
  format($$SELECT internal.fn_settle_delivery(%L); SELECT internal.fn_settle_delivery(%L)$$,
         tests.uid('t1_delivery'), tests.uid('t1_delivery')),
  'settling an already-settled delivery is a no-op, not an error');

SELECT is(tests.acct_balance('SELLER_PAYABLE:'||tests.uid('t1_seller')::text),
  10000::bigint, 'IDEMPOTENCY: three settlements still credit the seller exactly once');

SELECT is((SELECT count(*)::int FROM internal.ledger_transactions
            WHERE idempotency_key = 'settle:'||tests.uid('t1_delivery')::text),
  1, 'exactly one settlement transaction exists');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 2 — the defect at its sharpest.
--
-- Here the delivery quote carries the goods value (11000), which is what a
-- marketplace quote looks like the moment goods are priced into it. Against
-- the old function this is the catastrophic path: actual_goods_sen is NULL,
-- so v_refund = 11000 - 0 and the buyer was credited the entire product value
-- while the seller got nothing. The buyer would have kept the goods AND been
-- refunded for them.
-- ════════════════════════════════════════════════════════════════════════════
SELECT tests.mk_order_scenario('t2','penjual2', 11000, 1000, 2000, 0, 13000, true,
                               'SUCCEEDED', 11000);
SELECT internal.fn_allocate_order_payment(tests.uid('t2_payment'), tests.uid('t2_delivery'));
SELECT lives_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('t2_delivery')),
  'an order whose quote carries goods value settles');

SELECT is(tests.acct_balance('REQUESTER_REFUND:'||tests.uid('pembeli')::text), 0::bigint,
  'THE DEFECT: the buyer is not refunded the product value even though actual_goods_sen is NULL');

SELECT is(tests.acct_balance('SELLER_PAYABLE:'||tests.uid('t2_seller')::text), 10000::bigint,
  'THE FIX: the seller is paid from the allocation, not from budget arithmetic');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 3 — Kirim behaviour is untouched by this migration.
-- ════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE v_q UUID; v_d UUID;
BEGIN
  INSERT INTO internal.quotes (subject_type, requester_id, input_snapshot, breakdown,
    goods_budget_sen, delivery_fee_sen, commission_sen, total_sen,
    pricing_rule_version, expires_at)
  VALUES ('kirim', tests.uid('aisyah'), '{}'::jsonb, '{}'::jsonb,
    3500, 1000, 250, 4500,
    (SELECT version FROM internal.pricing_rules ORDER BY version DESC LIMIT 1),
    now() + interval '1 day')
  RETURNING id INTO v_q;

  UPDATE public.kirim_requests
     SET quote_id = v_q, actual_goods_sen = 2800, status = 'DELIVERED'
   WHERE id = tests.uid('_kirim');

  INSERT INTO public.deliveries (kirim_id, carrier_id, status, delivered_at)
  VALUES (tests.uid('_kirim'), tests.uid('_carrier'), 'DELIVERED', now())
  RETURNING id INTO v_d;

  INSERT INTO tests.handles (handle,user_id) VALUES ('t3_delivery', v_d)
  ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;

  PERFORM internal.fn_settle_delivery(v_d);
END $$;

SELECT is(tests.acct_balance('REQUESTER_REFUND:'||tests.uid('aisyah')::text), 700::bigint,
  'KIRIM UNCHANGED: unspent RM7 of a RM35 BELI budget still refunds to the requester');

SELECT is((SELECT count(*)::int FROM public.proofs WHERE delivery_id = tests.uid('t3_delivery')),
  0, 'KIRIM UNCHANGED: a Kirim still settles without a proofs row, as it did before');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 5 — an active dispute blocks settlement.
-- ════════════════════════════════════════════════════════════════════════════
SELECT tests.mk_order_scenario('t5','penjual3', 11000, 1000, 2000, 0, 13000);
SELECT internal.fn_allocate_order_payment(tests.uid('t5_payment'), tests.uid('t5_delivery'));

INSERT INTO public.disputes (delivery_id, raised_by, category, description, sla_due_at)
VALUES ((SELECT tests.uid('t5_delivery')), (SELECT tests.uid('pembeli')),
        'not_as_described', 'Barang rosak.', now() + interval '3 days');

SELECT is(internal.fn_settlement_blocked_reason(tests.uid('t5_delivery')),
  'ESCROW_HELD_BY_DISPUTE', 'an unresolved dispute blocks settlement');

SELECT throws_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('t5_delivery')),
  NULL, NULL, 'settling a disputed order is refused');

SELECT is(tests.acct_balance('SELLER_PAYABLE:'||tests.uid('t5_seller')::text), 0::bigint,
  'no money moves to the seller while the dispute is open');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 6 — missing proof of delivery blocks settlement.
-- ════════════════════════════════════════════════════════════════════════════
SELECT tests.mk_order_scenario('t6','penjual', 11000, 1000, 2000, 0, 13000, false);
SELECT internal.fn_allocate_order_payment(tests.uid('t6_payment'), tests.uid('t6_delivery'));
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('t6_delivery')), 'PROOF_MISSING',
  'an order with no dropoff proof cannot settle');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 7 — money that was never captured cannot be released.
-- ════════════════════════════════════════════════════════════════════════════
SELECT tests.mk_order_scenario('t7','penjual', 11000, 1000, 2000, 0, 13000, true, 'PENDING');
SELECT internal.fn_allocate_order_payment(tests.uid('t7_payment'), tests.uid('t7_delivery'));
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('t7_delivery')), 'PAYMENT_NOT_HELD',
  'an unpaid order cannot settle');

-- ── allocations missing entirely ────────────────────────────────────────────
SELECT tests.mk_order_scenario('t7b','penjual', 11000, 1000, 2000, 0, 13000);
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('t7b_delivery')), 'ALLOCATION_MISSING',
  'an order with no declared allocations cannot settle');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 9 / 10 / 11 / 12 — allocation invariants are enforced server-side.
-- ════════════════════════════════════════════════════════════════════════════
-- Parts (10000+2000+1000 = 13000) cannot sum to a payment of 99999.
SELECT tests.mk_order_scenario('t9','penjual', 11000, 1000, 2000, 0, 99999);
SELECT throws_ok(
  format($$SELECT internal.fn_allocate_order_payment(%L,%L)$$,
         tests.uid('t9_payment'), tests.uid('t9_delivery')),
  NULL, NULL, 'INVARIANT: allocations that do not sum to the payment are rejected');

-- Commission larger than the goods subtotal would make the seller's share negative.
SELECT tests.mk_order_scenario('t10','penjual', 1000, 5000, 2000, 0, 3000);
SELECT throws_ok(
  format($$SELECT internal.fn_allocate_order_payment(%L,%L)$$,
         tests.uid('t10_payment'), tests.uid('t10_delivery')),
  NULL, NULL, 'INVARIANT: a negative allocation is rejected');

-- A delivery belonging to a different order must not be allocated against.
SELECT tests.mk_order_scenario('t11','penjual2', 11000, 1000, 2000, 0, 13000);
SELECT throws_ok(
  format($$SELECT internal.fn_allocate_order_payment(%L,%L)$$,
         tests.uid('t11_payment'), tests.uid('t1_delivery')),
  NULL, NULL, 'INVARIANT: a payment cannot be allocated against another order''s delivery');

SELECT is((SELECT payee_id FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment') AND allocation_type='SELLER'),
  tests.uid('t1_seller'),
  'the seller allocation always names the order''s own seller');

SELECT is((SELECT payee_id FROM internal.payment_allocations
            WHERE payment_id = tests.uid('t1_payment') AND allocation_type='CARRIER'),
  tests.uid('_carrier'),
  'the carrier allocation always names the delivery''s own carrier');

-- Duplicate allocation rows are a constraint violation, not a double credit.
SELECT throws_ok(
  format($$INSERT INTO internal.payment_allocations
             (payment_id, order_id, allocation_type, payee_type, payee_id, amount_sen)
           VALUES (%L,%L,'SELLER','seller',%L,10000)$$,
         tests.uid('t1_payment'), tests.uid('t1_order'), tests.uid('t1_seller')),
  NULL, NULL, 'INVARIANT: a duplicate allocation for the same payment is rejected');

-- ════════════════════════════════════════════════════════════════════════════
-- TEST 13 / 14 — the client cannot touch any of this.
-- ════════════════════════════════════════════════════════════════════════════
SELECT ok(NOT has_schema_privilege('authenticated','internal','USAGE'),
  'SECURITY: authenticated has no USAGE on schema internal');

SELECT ok(
  NOT has_table_privilege('authenticated','internal.payment_allocations','SELECT')
  AND NOT has_table_privilege('authenticated','internal.payment_allocations','INSERT')
  AND NOT has_table_privilege('authenticated','internal.payment_allocations','UPDATE')
  AND NOT has_table_privilege('authenticated','internal.payment_allocations','DELETE'),
  'SECURITY: authenticated cannot read or write payment allocations');

SELECT ok(NOT has_table_privilege('authenticated','internal.ledger_entries','INSERT'),
  'SECURITY: authenticated cannot write ledger entries');

SELECT tests.clear_auth();
SELECT * FROM finish();
ROLLBACK;
