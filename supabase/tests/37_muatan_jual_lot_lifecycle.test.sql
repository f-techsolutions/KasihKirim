-- ============================================================================
-- 0047_muatan_jual_lot_lifecycle.sql regression tests.
--
-- Drives the whole missing loop this migration closes: a carrier applying
-- for the seller role as a carrier_trader (rpc_apply_seller's new params),
-- the gate off (master switch, then category, then seller onboarding --
-- each proven independently, in the same order internal.fn_marketplace_gate
-- itself checks them), admin review (rpc_admin_review_muatan_jual_seller),
-- the seller's own terms acceptance (rpc_accept_muatan_jual_terms), R-1's
-- two caps on rpc_create_lot (history + value ceiling), the float-limit
-- exposure check, attach/withdraw, admin category-compliance and
-- licence-verification RPCs, and -- the actual security fix -- that a raw
-- INSERT into carrier_stock_lots (the gap this migration closes) no longer
-- works now that lots_write is gone.
--
-- ref.compliance_state/ref.feature_gates/ref.category_compliance are
-- flipped ON partway through, same as
-- 35_kongsi_untung_promotions.test.sql's own pattern. ROLLBACK at the end
-- leaves production's rows untouched.
-- ============================================================================
BEGIN;
SELECT plan(37);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- ── seller application first -- it needs no gate at all ────────────────────
DO $$
DECLARE v_kepayan UUID; v_result JSONB;
BEGIN
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  PERFORM tests.authenticate_as('rahman');
  v_result := public.rpc_apply_seller('Rahman Muatan Jual', v_kepayan, NULL, 'carrier_trader');
  PERFORM tests.clear_auth();
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_mjseller', (v_result->>'seller_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is(
  (SELECT seller_kind FROM public.sellers WHERE id = tests.uid('_mjseller')),
  'carrier_trader', 'rpc_apply_seller''s new p_seller_kind param is stored');
SELECT is(
  (SELECT onboarding_status::text FROM public.sellers WHERE id = tests.uid('_mjseller')),
  'PENDING', 'a fresh application starts PENDING, the same as every other onboarding_status row');

-- ── the gates, off by default, each proven independently ────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 10000, 'lot-receipts/x/y.jpg', 3000)$$,
  NULL, NULL, 'MARKETPLACE_NOT_ACTIVE: ref.compliance_state is NOT_READY by default');
SELECT tests.clear_auth();

UPDATE ref.compliance_state SET status = 'PRODUCTION_ACTIVE' WHERE id;

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 10000, 'lot-receipts/x/y.jpg', 3000)$$,
  NULL, NULL, 'MARKETPLACE_DISABLED: muatan_jual_enabled is still false');
SELECT tests.clear_auth();

UPDATE ref.feature_gates SET enabled = true WHERE key = 'muatan_jual_enabled';

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 10000, 'lot-receipts/x/y.jpg', 3000)$$,
  NULL, NULL, 'CATEGORY_NOT_PERMITTED: kraf is not marketplace_enabled yet');
SELECT tests.clear_auth();

UPDATE ref.category_compliance SET marketplace_enabled = true
 WHERE category_id = (SELECT id FROM ref.categories WHERE slug='kraf');

SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 10000, 'lot-receipts/x/y.jpg', 3000)$$,
  NULL, NULL, 'SELLER_NOT_ACTIVE: onboarding_status is still PENDING');
SELECT tests.clear_auth();

-- ── admin review, then the seller's own acceptance step ─────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_review_muatan_jual_seller(%L, 'APPROVED')$$, tests.uid('_mjseller')),
  NULL, NULL, 'a non-admin cannot review a Muatan Jual seller application');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_review_muatan_jual_seller(%L, 'BOGUS')$$, tests.uid('_mjseller')),
  NULL, NULL, 'an invalid target status is rejected');
SELECT is(
  (public.rpc_admin_review_muatan_jual_seller(tests.uid('_mjseller'), 'APPROVED'))->>'onboarding_status',
  'APPROVED', 'the admin moves the application to APPROVED');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_accept_muatan_jual_terms())->>'onboarding_status',
  'ACTIVE', 'accepting terms moves APPROVED -> ACTIVE');
SELECT is(
  (SELECT terms_accepted_at IS NOT NULL FROM public.sellers WHERE id = tests.uid('_mjseller')),
  true, 'terms_accepted_at is stamped -- the column 0007 added and nothing ever wrote until now');
SELECT throws_ok(
  'SELECT public.rpc_accept_muatan_jual_terms()',
  NULL, NULL, 'accepting again is refused -- onboarding_status is no longer APPROVED');
SELECT tests.clear_auth();

-- ── R-1: history required before selling ────────────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 10000, 'lot-receipts/x/y.jpg', 3000)$$,
  NULL, NULL, 'LOT_HISTORY_REQUIRED: rahman has 0 completed deliveries, needs 20');
SELECT tests.clear_auth();

-- Raw fixture setup, same as every other test file's direct UPDATEs
-- against carriers/sellers/etc. -- runs as postgres (tests.clear_auth
-- above), not as rahman, since a carrier cannot write their own
-- completed_count via RLS (nor should they be able to).
UPDATE public.carriers SET completed_count = 20 WHERE id = tests.uid('_carrier');

-- ── R-1: the RM200 ceiling, and basic input validation ──────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 25000, 'lot-receipts/x/y.jpg', 3000)$$,
  NULL, NULL, 'a cost basis above lot_max_value_sen (RM200) is refused');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Ikan kering', 'kraf',
      5, 10000, NULL, 3000)$$,
  NULL, NULL, 'a lot with no cost receipt path is refused -- FR-441''s own requirement');
SELECT tests.clear_auth();

-- ── the real creation ────────────────────────────────────────────────────────
DO $$
DECLARE v_result JSONB;
BEGIN
  PERFORM tests.authenticate_as('rahman');
  v_result := public.rpc_create_lot(
    'Ikan Kering Beluran', 'kraf',
    10, 15000, 'lot-receipts/rahman/receipt.jpg', 2500, 'kg', ARRAY['PERISHABLE'], ARRAY[]::text[],
    now() + interval '3 days');
  PERFORM tests.clear_auth();
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_lot37', (v_result->>'lot_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is(
  (SELECT status::text FROM public.carrier_stock_lots WHERE id = tests.uid('_lot37')),
  'DRAFT', 'a new lot starts DRAFT, not visible until attached to a trip');
SELECT is(
  (SELECT inventory_at_risk_sen FROM public.carriers WHERE id = tests.uid('_carrier')),
  15000::bigint, 'inventory_at_risk_sen rises by the lot''s own cost basis');
SELECT ok(
  EXISTS (SELECT 1 FROM internal.ledger_transactions
          WHERE reference_type='lot' AND reference_id=tests.uid('_lot37') AND kind='LOT_INVENTORY_PURCHASE'),
  'the carrier''s own capital is posted to the ledger at lot creation (ADDENDUM-COMMERCE.md §5.4)');

-- ── the float-limit exposure check (ck_carrier_exposure, 0006) ──────────────
-- 30000 clears ck_carrier_exposure on its own against the first lot's
-- inventory_at_risk_sen (30000+0+15000=45000 <= float_limit_sen 50000), but
-- adding a second 15000 lot on top (60000) is what rpc_create_lot itself
-- must refuse.
UPDATE public.carriers SET cod_held_sen = 30000 WHERE id = tests.uid('_carrier');
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$SELECT public.rpc_create_lot('Another lot', 'kraf',
      5, 15000, 'lot-receipts/rahman/receipt2.jpg', 3000)$$,
  NULL, NULL, 'FLOAT_LIMIT_EXCEEDED: COD + procurement advance + inventory risk already exceeds float_limit_sen');
SELECT tests.clear_auth();
UPDATE public.carriers SET cod_held_sen = 0 WHERE id = tests.uid('_carrier');

-- ── the actual security fix: a raw client write no longer works ────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  $$INSERT INTO public.carrier_stock_lots
      (carrier_id, seller_id, title, category_id, qty_total, cost_basis_sen,
       cost_receipt_path, price_per_unit_sen, status)
    VALUES (tests.uid('_carrier'), tests.uid('_mjseller'), 'Sneaky lot',
      (SELECT id FROM ref.categories WHERE slug='kraf'), 999, 999999, 'x', 1, 'ACTIVE')$$,
  NULL, NULL,
  'a raw INSERT is refused now that lots_write is gone -- rpc_create_lot is the only write path');
SELECT tests.clear_auth();

-- ── attach to trip (FR-442) ──────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_attach_lot_to_trip(%L, %L)$$, tests.uid('_lot37'), tests.uid('_trip')),
  NULL, NULL, 'a stranger cannot attach someone else''s lot to a trip');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_attach_lot_to_trip(tests.uid('_lot37'), tests.uid('_trip')))->>'status',
  'ACTIVE', 'attaching a DRAFT lot to the carrier''s own trip activates it');
SELECT is(
  (SELECT trip_id FROM public.carrier_stock_lots WHERE id = tests.uid('_lot37')),
  tests.uid('_trip'), 'the lot records which trip it is riding on');
SELECT ok(
  EXISTS (SELECT 1 FROM public.trip_listings
          WHERE lot_id = tests.uid('_lot37') AND trip_id = tests.uid('_trip') AND is_active),
  'trip_listings gets a row so the lot is visible on Papan Kirim along that corridor');
SELECT throws_ok(
  format($$SELECT public.rpc_attach_lot_to_trip(%L, %L)$$, tests.uid('_lot37'), tests.uid('_trip')),
  NULL, NULL, 'attaching an already-ACTIVE lot again is refused -- it is no longer DRAFT');
SELECT tests.clear_auth();

-- A buyer (not the carrier) can now see the ACTIVE lot -- lots_select's own
-- buyer branch, unaffected by this migration's write-side changes.
SELECT tests.authenticate_as('stranger');
SELECT ok(
  EXISTS (SELECT 1 FROM public.carrier_stock_lots WHERE id = tests.uid('_lot37')),
  'once ACTIVE, any buyer can see the lot through lots_select''s own status=ACTIVE branch');
SELECT tests.clear_auth();

-- ── withdraw ─────────────────────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_withdraw_lot(%L)$$, tests.uid('_lot37')),
  NULL, NULL, 'a stranger cannot withdraw someone else''s lot');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_withdraw_lot(tests.uid('_lot37')))->>'status',
  'WITHDRAWN', 'the carrier can withdraw their own lot from sale');
SELECT tests.clear_auth();

-- listings_select (0006) is `is_active OR authz.is_admin()' -- once
-- deactivated, even the owning carrier can no longer see the row through
-- plain SELECT, so this check needs an admin.
SELECT tests.authenticate_as('admin');
SELECT is(
  (SELECT is_active FROM public.trip_listings WHERE lot_id = tests.uid('_lot37')),
  false, 'withdrawing deactivates the trip listing');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('rahman');
SELECT is(
  (SELECT inventory_at_risk_sen FROM public.carriers WHERE id = tests.uid('_carrier')),
  15000::bigint, 'withdrawing does NOT relieve inventory_at_risk_sen -- the carrier still holds the physical stock');
SELECT throws_ok(
  format($$SELECT public.rpc_withdraw_lot(%L)$$, tests.uid('_lot37')),
  NULL, NULL, 'withdrawing an already-WITHDRAWN lot is refused');
SELECT tests.clear_auth();

-- ── admin: category compliance and licence verification ─────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_update_category_compliance(%L, p_compliance_note := 'nope')$$,
    (SELECT id::text FROM ref.categories WHERE slug='kraf')),
  NULL, NULL, 'a non-admin cannot touch category compliance');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT throws_ok(
  $$SELECT public.rpc_admin_update_category_compliance(gen_random_uuid())$$,
  NULL, NULL, 'a nonexistent category id is refused');
SELECT is(
  (public.rpc_admin_update_category_compliance(
    (SELECT id FROM ref.categories WHERE slug='kraf'),
    p_legal_review_status := 'CLEARED', p_compliance_note := 'Reviewed for this test'
  ))->>'legal_review_status',
  'CLEARED', 'an admin can move a category''s legal_review_status');
SELECT tests.clear_auth();

-- Raw fixture insert, same reasoning as every other direct INSERT in this
-- file -- runs as postgres, not as any authenticated actor: a licence row
-- for _mjseller inserted while authenticated as anyone else would violate
-- seller_licences_insert's own WITH CHECK (seller_id must match the
-- caller's own sellers row).
DO $$
DECLARE v_licence UUID;
BEGIN
  INSERT INTO public.seller_licences
    (seller_id, licence_no, licence_type, issuing_authority, issue_date, expiry_date, document_path)
  VALUES (tests.uid('_mjseller'), 'LIC-37-001', 'Fisheries', 'Sabah Dept of Fisheries',
    current_date, current_date + interval '1 year', 'lot-receipts/rahman/licence.jpg')
  RETURNING id INTO v_licence;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_licence37', v_licence)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT is(
  (public.rpc_admin_verify_seller_licence(tests.uid('_licence37'), true))->>'verification_status',
  'VERIFIED', 'an admin can verify a submitted licence');
SELECT throws_ok(
  $$SELECT public.rpc_admin_verify_seller_licence(gen_random_uuid(), true)$$,
  NULL, NULL, 'verifying a nonexistent licence id is refused');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_verify_seller_licence(%L, true)$$, tests.uid('_licence37')),
  NULL, NULL, 'a non-admin cannot verify a licence');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
