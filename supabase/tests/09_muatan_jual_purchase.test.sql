-- ============================================================================
-- rpc_buy_from_lot's marketplace gate + persistence (0013). Closes the gap
-- flagged in docs/SECURITY.md and the Android implementation notes: the
-- function's compliance check went dead when 0007 replaced app_config's
-- feature_flags with ref.feature_gates, and it never recorded who bought
-- what -- see 0013's own header comment for the full diagnosis.
-- ============================================================================
BEGIN;
SELECT plan(13);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- A seller of record + an ACTIVE lot in 'kraf' (no licence required), owned
-- by rahman's carrier. Gates start closed -- seed_fixture's defaults.
DO $$
DECLARE v_cat UUID; v_seller UUID; v_lot UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug='kraf';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,onboarding_status)
  VALUES (tests.uid('rahman'),'Kraf Rahman',
          (SELECT id FROM public.communities LIMIT 1),'APPROVED','ACTIVE')
  RETURNING id INTO v_seller;

  UPDATE ref.category_compliance SET marketplace_enabled=true WHERE category_id=v_cat;

  INSERT INTO public.carrier_stock_lots (carrier_id,seller_id,title,category_id,
    qty_total,cost_basis_sen,cost_receipt_path,price_per_unit_sen,status)
  VALUES (tests.uid('_carrier'),v_seller,'Anyaman tikar',v_cat,
    10,3000,'r.jpg',1000,'ACTIVE')
  RETURNING id INTO v_lot;

  INSERT INTO tests.handles (handle,user_id) VALUES ('_mjseller',v_seller),('_mjlot',v_lot)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- ── The gate blocks a purchase while the marketplace is closed ─────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_buy_from_lot(%L, 2)$$, tests.uid('_mjlot')),
  NULL, NULL,
  'a purchase is blocked while compliance_status is NOT_READY -- this is the bug 0013 fixes');

-- ── Open the marketplace + checkout gates for this category ────────────────
SELECT tests.clear_auth();
UPDATE ref.compliance_state SET status='PRODUCTION_ACTIVE' WHERE id;
UPDATE ref.feature_gates SET enabled=true
 WHERE key IN ('muatan_jual_enabled','muatan_jual_checkout_enabled');

-- ── BR-910: a carrier cannot buy their own stock ────────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_buy_from_lot(%L, 2)$$, tests.uid('_mjlot')),
  NULL, NULL, 'BR-910: a carrier cannot buy from their own lot');

-- ── A real purchase reserves qty and persists the reservation ──────────────
SELECT tests.authenticate_as('aisyah');
DO $$
DECLARE v_result JSONB;
BEGIN
  v_result := public.rpc_buy_from_lot(tests.uid('_mjlot'), 2, 'buy-once');
  INSERT INTO tests.handles (handle,user_id)
    VALUES ('_mjpurchase',(v_result->>'purchase_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT qty_reserved FROM public.carrier_stock_lots WHERE id=tests.uid('_mjlot')),
  2::numeric, 'the purchased quantity is reserved on the lot');

SELECT is((SELECT goods_sen FROM public.lot_purchases WHERE id=tests.uid('_mjpurchase')),
  2000::bigint, '2 units at RM10.00 each is RM20.00 in goods');

SELECT is((SELECT commission_sen FROM public.lot_purchases WHERE id=tests.uid('_mjpurchase')),
  200::bigint, '10% commission on goods is RM2.00');

SELECT is((SELECT carrier_sen FROM public.lot_purchases WHERE id=tests.uid('_mjpurchase')),
  1800::bigint, 'the carrier keeps the remaining RM18.00');

SELECT is((SELECT buyer_id FROM public.lot_purchases WHERE id=tests.uid('_mjpurchase')),
  tests.uid('aisyah'), 'the purchase is attributed to the actual buyer, not just the lot');

-- ── Idempotency: a retried request does not double-reserve ─────────────────
SELECT lives_ok(
  format($$SELECT public.rpc_buy_from_lot(%L, 2, 'buy-once')$$, tests.uid('_mjlot')),
  'replaying the same idempotency key succeeds without a second effect');

SELECT is((SELECT qty_reserved FROM public.carrier_stock_lots WHERE id=tests.uid('_mjlot')),
  2::numeric, 'qty_reserved is unchanged by the replayed request');

SELECT is((SELECT count(*) FROM public.lot_purchases WHERE idempotency_key='buy-once'), 1::bigint,
  'the replay did not insert a second lot_purchases row');

-- ── Overselling is still refused through the RPC, not just the CHECK ───────
SELECT throws_ok(
  format($$SELECT public.rpc_buy_from_lot(%L, 100)$$, tests.uid('_mjlot')),
  NULL, NULL, 'buying more than remains in the lot is rejected');

-- ── RLS: a buyer sees their own purchase; an unrelated user does not ───────
SELECT is((SELECT count(*) FROM public.lot_purchases WHERE id=tests.uid('_mjpurchase')), 1::bigint,
  'the buyer can read their own purchase');

SELECT tests.authenticate_as('stranger');
SELECT is((SELECT count(*) FROM public.lot_purchases WHERE id=tests.uid('_mjpurchase')), 0::bigint,
  'an unrelated user cannot read someone else''s purchase');

SELECT * FROM finish();
ROLLBACK;
