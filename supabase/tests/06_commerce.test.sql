-- ============================================================================
-- Carrier commerce invariants (0006).
-- ============================================================================
BEGIN;
SELECT plan(10);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- ── Commission decisions are encoded, not assumed ──────────────────────────
SELECT is((SELECT rate_bps FROM internal.commission_rules
           WHERE context='muatan_jual' AND basis='goods_subtotal'
             AND effective_to IS NULL), 1000,
  'Muatan Jual goods commission is 10%');

SELECT is((SELECT rate_bps FROM internal.commission_rules
           WHERE context='muatan_jual' AND basis='delivery_fee'
             AND effective_to IS NULL), 2500,
  'the delivery leg still earns the full 25% service rate');

SELECT is((SELECT max_commission_sen FROM internal.commission_rules
           WHERE context='promoter' AND effective_to IS NULL), 1000::bigint,
  'promoter commission capped at RM10');

-- ── FR-448: three kinds of exposure, one limit ─────────────────────────────
SELECT throws_ok(
  format($$UPDATE public.carriers SET cod_held_sen=20000,
             procurement_advance_sen=20000, inventory_at_risk_sen=20000
           WHERE id=%L$$, tests.uid('_carrier')),
  '23514', NULL,
  'ck_carrier_exposure counts COD + advance + inventory together');

SELECT lives_ok(
  format($$UPDATE public.carriers SET cod_held_sen=20000,
             procurement_advance_sen=20000, inventory_at_risk_sen=10000
           WHERE id=%L$$, tests.uid('_carrier')),
  'exposure exactly at the float limit is allowed');

-- ── A lot cannot be oversold ───────────────────────────────────────────────
DO $$
DECLARE v_seller UUID; v_lot UUID;
BEGIN
  INSERT INTO public.sellers (user_id,business_name,community_id,status)
  VALUES (tests.uid('rahman'),'Rahman Trading',
          (SELECT id FROM public.communities LIMIT 1),'APPROVED')
  RETURNING id INTO v_seller;

  INSERT INTO public.carrier_stock_lots (carrier_id,seller_id,title,category_id,
    handling_flags,qty_total,cost_basis_sen,cost_receipt_path,
    price_per_unit_sen,status,sell_by)
  VALUES (tests.uid('_carrier'), v_seller,'Langsat Kg Toboh',
    (SELECT id FROM ref.categories WHERE slug='buah'),
    '{PERISHABLE}',20,16000,'receipts/langsat.jpg',1200,'ACTIVE',
    now()+interval '2 days')
  RETURNING id INTO v_lot;

  INSERT INTO tests.handles (handle,user_id) VALUES ('_lot',v_lot)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT throws_ok(
  format($$UPDATE public.carrier_stock_lots SET qty_sold=21 WHERE id=%L$$,
         tests.uid('_lot')),
  '23514', NULL, 'ck_lot_not_oversold blocks selling more than the lot holds');

SELECT lives_ok(
  format($$UPDATE public.carrier_stock_lots SET qty_sold=20 WHERE id=%L$$,
         tests.uid('_lot')),
  'selling the entire lot is allowed');

-- ── Perishables must declare a window (FR-445) ─────────────────────────────
SELECT throws_ok(
  $$INSERT INTO public.carrier_stock_lots (carrier_id,seller_id,title,category_id,
      handling_flags,qty_total,cost_basis_sen,cost_receipt_path,price_per_unit_sen)
    SELECT tests.uid('_carrier'),(SELECT id FROM public.sellers LIMIT 1),'Ikan',
      (SELECT id FROM ref.categories WHERE slug='hasil-laut'),
      '{PERISHABLE}',10,5000,'r.jpg',900$$,
  '23514', NULL, 'a perishable lot without sell_by is rejected');

-- ── Promoter can never be paid more than the platform earned ───────────────
SELECT throws_ok(
  format($$INSERT INTO public.promotion_attributions
      (promotion_id,buyer_id,order_id,order_total_sen,
       platform_commission_sen,promoter_sen)
    VALUES (gen_random_uuid(),%L,gen_random_uuid(),24000,2400,3000)$$,
    tests.uid('aisyah')),
  NULL, NULL, 'promoter payout cannot exceed platform commission');

-- ── Muatan Jual is closed until legal clears ───────────────────────────────
-- 0007 superseded app_config.feature_flags with ref.feature_gates; the old key
-- now holds a pointer, so value->>'muatan_jual' was NULL. Read the live source.
SELECT is((SELECT enabled FROM ref.feature_gates WHERE key='muatan_jual_enabled'), false,
  'muatan_jual feature flag is OFF pending LGL-02/13/14/15');

SELECT * FROM finish();
ROLLBACK;
