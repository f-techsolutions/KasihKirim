-- ============================================================================
-- Money. The commission rate, the refund invariant, and reconciliation.
-- ============================================================================
BEGIN;
SELECT plan(11);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- ── Pricing: banded distance, 25% of order total ───────────────────────────
CREATE TEMP TABLE q AS
SELECT * FROM internal.fn_quote_kirim(
  'BELI',
  (SELECT id FROM ref.categories WHERE slug='hasil-laut'),
  2000, 8000, 3500,
  (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
  (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
  '{PERISHABLE,COLD_CHAIN}'::ref.handling_flag[], 'COD',
  tests.uid('aisyah'));

SELECT is((SELECT corridor_band FROM q), 'long_haul',
  'Beluran -> KK resolves to the long_haul band');

SELECT ok((SELECT corridor_km FROM q) BETWEEN 250 AND 280,
  'corridor distance is ~266 km via Telupid');

SELECT is((SELECT goods_budget_sen FROM q), 3500::bigint,
  'goods budget passes through untouched');

-- Commission is exactly 25% of order total, and order total is goods+delivery.
SELECT is((SELECT total_sen FROM q),
          (SELECT goods_budget_sen + delivery_fee_sen FROM q),
  'order total = goods budget + delivery fee');

SELECT is((SELECT commission_sen FROM q),
          (SELECT total_sen * 2500 / 10000 FROM q),
  'commission is 25% of order total');

-- The whole reason for banded pricing: per-km gave RM120 here against a deck
-- order value of RM50. Delivery must stay a sane fraction of the order.
SELECT ok((SELECT delivery_fee_sen FROM q) < 2500,
  'delivery fee on a 266km corridor stays under RM25 (banded, not metered)');

-- ── BR-915: unspent budget always returns ──────────────────────────────────
DO $$
DECLARE v_d UUID; v_q UUID;
BEGIN
  SELECT id INTO v_q FROM q;
  UPDATE public.kirim_requests
     SET quote_id=v_q, actual_goods_sen=2800, status='DELIVERED'
   WHERE id=tests.uid('_kirim');
  INSERT INTO public.deliveries (kirim_id,carrier_id,status,delivered_at)
  VALUES (tests.uid('_kirim'), tests.uid('_carrier'),'DELIVERED', now())
  RETURNING id INTO v_d;
  PERFORM internal.fn_settle_delivery(v_d);
END $$;

SELECT is(
  (SELECT SUM(amount_sen)::bigint FROM internal.ledger_entries e
   JOIN internal.ledger_accounts a ON a.id=e.account_id
   WHERE a.account_code LIKE 'REQUESTER_REFUND:%' AND e.direction='CREDIT'),
  700::bigint,
  'unspent RM7.00 of the RM35 budget is refunded to the requester');

SELECT is(
  (SELECT SUM(amount_sen)::bigint FROM internal.ledger_entries e
   JOIN internal.ledger_accounts a ON a.id=e.account_id
   WHERE a.account_code = 'PLATFORM_COMMISSION' AND e.direction='CREDIT'),
  (SELECT commission_sen FROM q),
  'platform commission posted exactly once, at the quoted amount');

-- Goods are reimbursed AT COST. The platform never marks up a villager's
-- groceries, and never quietly keeps the change.
SELECT is(
  (SELECT SUM(e.amount_sen)::bigint FROM internal.ledger_entries e
   JOIN internal.ledger_accounts a ON a.id=e.account_id
   WHERE a.account_code LIKE 'CARRIER_PAYABLE:%' AND e.direction='CREDIT'),
  2800 + ((SELECT delivery_fee_sen FROM q) - (SELECT commission_sen FROM q)),
  'carrier receives cost reimbursement plus service earnings, nothing more');

-- ── Reconciliation: the daily proof ────────────────────────────────────────
SELECT is((SELECT variance_sen FROM internal.fn_reconcile()
           WHERE check_name='global_balance'), 0::bigint,
  'ledger balances globally after settlement');

SELECT ok((SELECT bool_and(ok) FROM internal.fn_reconcile()),
  'all reconciliation checks pass');

SELECT * FROM finish();
ROLLBACK;
