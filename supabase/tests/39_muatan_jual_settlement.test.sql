-- ============================================================================
-- 0049_muatan_jual_settlement.sql regression tests.
--
-- Drives a lot purchase all the way through: reserve (rpc_buy_from_lot,
-- 0013), then settle (rpc_confirm_lot_handover, 0049) -- the two accounts
-- it touches (carriers.cod_held_sen, carriers.inventory_at_risk_sen) move
-- in the same breath, the ledger balances, qty_reserved/qty_sold move
-- correctly, a retried confirm is a no-op rather than a double-post, and
-- the float-limit exposure check (ck_carrier_exposure, 0006) still refuses
-- a settlement that would push the carrier over their own float_limit_sen.
--
-- ref.compliance_state/ref.feature_gates/ref.category_compliance are
-- flipped ON, same pattern as 37_muatan_jual_lot_lifecycle.test.sql's own.
-- ROLLBACK at the end leaves production's rows untouched.
-- ============================================================================
BEGIN;
SELECT plan(13);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- ── fixture: an ACTIVE carrier_trader seller with completed-delivery
-- history, and a real lot, replaying 37_muatan_jual_lot_lifecycle's own
-- gate-flip + onboarding sequence (already proven there test by test) in
-- one pass since this file only needs the end state, not to re-prove it.
UPDATE ref.compliance_state SET status = 'PRODUCTION_ACTIVE' WHERE id;
UPDATE ref.feature_gates SET enabled = true
 WHERE key IN ('muatan_jual_enabled','muatan_jual_checkout_enabled');
UPDATE ref.category_compliance SET marketplace_enabled = true
 WHERE category_id = (SELECT id FROM ref.categories WHERE slug='kraf');
UPDATE public.carriers SET completed_count = 20 WHERE id = tests.uid('_carrier');

DO $$
DECLARE v_kepayan UUID; v_seller UUID; v_lot UUID; v_purchase JSONB;
BEGIN
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  PERFORM tests.authenticate_as('rahman');
  PERFORM public.rpc_apply_seller('Rahman Muatan Jual', v_kepayan, NULL, 'carrier_trader');
  PERFORM tests.clear_auth();

  SELECT id INTO v_seller FROM public.sellers WHERE user_id = tests.uid('rahman');
  PERFORM tests.authenticate_as('admin');
  PERFORM public.rpc_admin_review_muatan_jual_seller(v_seller, 'APPROVED');
  PERFORM tests.clear_auth();
  PERFORM tests.authenticate_as('rahman');
  PERFORM public.rpc_accept_muatan_jual_terms();

  -- cost_basis_sen 15000 (RM150, under R-1's RM200 ceiling), qty_total 10,
  -- price_per_unit_sen 2500 -- the same real values
  -- 37_muatan_jual_lot_lifecycle.test.sql's own "real creation" section uses.
  v_lot := (public.rpc_create_lot(
    'Ikan Kering Beluran', 'kraf', 10, 15000, 'lot-receipts/rahman/receipt.jpg', 2500
  )->>'lot_id')::uuid;
  -- A new lot starts DRAFT (37_muatan_jual_lot_lifecycle.test.sql's own
  -- comment) -- rpc_buy_from_lot refuses anything but ACTIVE, so it has to
  -- be attached to the carrier's own _trip fixture (seed_fixture, BOARDING)
  -- before aisyah can buy from it.
  PERFORM public.rpc_attach_lot_to_trip(v_lot, tests.uid('_trip'));
  PERFORM tests.clear_auth();

  INSERT INTO tests.handles(handle,user_id) VALUES ('_seller39', v_seller), ('_lot39', v_lot)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  -- aisyah buys 2kg: goods_sen 5000, commission_sen (10%) 500, carrier_sen 4500.
  PERFORM tests.authenticate_as('aisyah');
  v_purchase := public.rpc_buy_from_lot(v_lot, 2);
  PERFORM tests.clear_auth();
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_purchase39', (v_purchase->>'purchase_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- ── authorization ────────────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_confirm_lot_handover(%L)$$, tests.uid('_purchase39')),
  NULL, NULL, 'a non-carrier cannot confirm a lot handover');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  'SELECT public.rpc_confirm_lot_handover(gen_random_uuid())',
  NULL, NULL, 'a nonexistent purchase id is refused');

-- ── the real settlement ──────────────────────────────────────────────────
-- Still authenticated as 'rahman' from the throws_ok just above -- the RPC
-- itself must run as the carrier. Everything after it reads internal.*
-- tables directly, which authenticated has no grant on at all
-- (02_rls.test.sql's own throws_ok already proves that) -- clear_auth
-- first, the same "verify as postgres" pattern 15_order_settlement.test.sql
-- uses for every one of its own ledger-balance checks.
SELECT is(
  (public.rpc_confirm_lot_handover(tests.uid('_purchase39')))->>'status',
  'SETTLED', 'the carrier settles their own buyer''s purchase');
SELECT tests.clear_auth();

SELECT is(
  (SELECT (SUM(CASE WHEN direction='DEBIT' THEN amount_sen ELSE -amount_sen END))::int
     FROM internal.ledger_entries e
     JOIN internal.ledger_transactions t ON t.id = e.transaction_id
    WHERE t.idempotency_key = 'lot_settle:'||tests.uid('_purchase39')::text),
  0, 'the settlement''s own ledger transaction balances (debits = credits)');
SELECT is(
  (SELECT qty_reserved FROM public.carrier_stock_lots WHERE id = tests.uid('_lot39')),
  0::numeric, 'settling relieves the lot''s own qty_reserved');
SELECT is(
  (SELECT qty_sold FROM public.carrier_stock_lots WHERE id = tests.uid('_lot39')),
  2::numeric, 'settling raises qty_sold by the purchase''s own qty -- 0006''s fn_expire_lots can now tell a sold unit from an unsold one');
SELECT is(
  (SELECT cod_held_sen FROM public.carriers WHERE id = tests.uid('_carrier')),
  5000::bigint, 'the carrier''s cod exposure rises by the full goods_sen collected, same reasoning as a regular COD delivery');
SELECT is(
  (SELECT inventory_at_risk_sen FROM public.carriers WHERE id = tests.uid('_carrier')),
  12000::bigint, 'inventory_at_risk_sen falls by the cost of the 2kg actually sold (15000 - 3000)');
SELECT ok(
  EXISTS (SELECT 1 FROM internal.ledger_entries e
          JOIN internal.ledger_accounts a ON a.id = e.account_id
          JOIN internal.ledger_transactions t ON t.id = e.transaction_id
          WHERE t.idempotency_key = 'lot_settle:'||tests.uid('_purchase39')::text
            AND a.account_code = 'PLATFORM_COMMISSION' AND e.direction = 'CREDIT'
            AND e.amount_sen = 500),
  'the platform''s own 10% commission is posted');

-- ── idempotent retry ─────────────────────────────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_confirm_lot_handover(tests.uid('_purchase39')))->>'status',
  'ALREADY_SETTLED', 'confirming the same purchase twice is a no-op, not a second sale');
SELECT tests.clear_auth();
SELECT is(
  (SELECT cod_held_sen FROM public.carriers WHERE id = tests.uid('_carrier')),
  5000::bigint, 'the retry did not post a second time -- cod_held_sen is unchanged');

-- ── float-limit exposure still guards this path ─────────────────────────
UPDATE public.carriers SET cod_held_sen = 40000 WHERE id = tests.uid('_carrier');
DO $$
DECLARE v_purchase2 JSONB;
BEGIN
  PERFORM tests.authenticate_as('aisyah');
  -- 3kg more: goods_sen 7500, would raise cod_held_sen to 47500 and
  -- (after relieving 4500 of inventory_at_risk_sen) exposure to 55000,
  -- over the fixture carrier's own 50000 float_limit_sen.
  v_purchase2 := public.rpc_buy_from_lot(tests.uid('_lot39'), 3);
  PERFORM tests.clear_auth();
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_purchase39b', (v_purchase2->>'purchase_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_confirm_lot_handover(%L)$$, tests.uid('_purchase39b')),
  NULL, NULL, 'FLOAT_LIMIT_EXCEEDED: settling would push the carrier over their own float limit');
SELECT tests.clear_auth();
UPDATE public.carriers SET cod_held_sen = 5000 WHERE id = tests.uid('_carrier');

-- ── the master gate still guards this path, not just the float limit ────
-- The whole reason this RPC can exist ahead of MJ-01 (docs/MUATAN-JUAL-
-- COMPLIANCE.md §8/§14): whatever a client sends, muatan_jual_checkout_
-- enabled off refuses it before the float-limit check (or anything else)
-- is ever reached. Re-checking _purchase39b (still unsettled -- its own
-- settlement failed on the float limit above) proves the gate call is for
-- real, not decoration.
UPDATE ref.feature_gates SET enabled = false WHERE key = 'muatan_jual_checkout_enabled';
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_confirm_lot_handover(%L)$$, tests.uid('_purchase39b')),
  NULL, NULL, 'CHECKOUT_DISABLED: turning the gate back off refuses settlement outright, ahead of the float-limit check');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
