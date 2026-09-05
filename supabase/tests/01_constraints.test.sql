-- ============================================================================
-- Constraint tests. Each asserts the DATABASE refuses — not that application
-- code declined. These are the invariants that survive a future bug.
-- ============================================================================
BEGIN;
SELECT plan(14);
SELECT tests.seed_fixture();

-- ── BR-903: overbooking is structurally impossible ─────────────────────────
SELECT throws_ok(
  format($$UPDATE public.trips SET reserved_weight_grams = capacity_weight_grams + 1
           WHERE id = %L$$, tests.uid('_trip')),
  '23514', NULL, 'ck_trip_weight_capacity blocks weight overbooking');

SELECT throws_ok(
  format($$UPDATE public.trips SET reserved_parcels = capacity_parcels + 1
           WHERE id = %L$$, tests.uid('_trip')),
  '23514', NULL, 'ck_trip_parcel_capacity blocks parcel overbooking');

-- Reserving exactly to capacity must SUCCEED. A guard that blocks the last
-- legitimate slot is as broken as one that allows an extra.
SELECT lives_ok(
  format($$SELECT internal.fn_reserve_capacity(%L,%L,10000,500000,5)$$,
         tests.uid('_trip'), tests.uid('_kirim')),
  'reserving exactly to capacity succeeds');

SELECT is((SELECT reserved_weight_grams FROM public.trips WHERE id=tests.uid('_trip')),
  10000, 'trigger synced reserved weight to exactly capacity');

-- ── BR-908: COD + procurement advance share ONE float limit ────────────────
SELECT throws_ok(
  format($$UPDATE public.carriers
           SET cod_held_sen=40000, procurement_advance_sen=20000 WHERE id=%L$$,
         tests.uid('_carrier')),
  '23514', NULL, 'ck_carrier_exposure blocks combined float breach');

SELECT lives_ok(
  format($$UPDATE public.carriers
           SET cod_held_sen=30000, procurement_advance_sen=20000 WHERE id=%L$$,
         tests.uid('_carrier')),
  'exposure exactly at the limit is allowed');

-- ── BR-913: budget cap needs an approved variance to be exceeded ───────────
SELECT throws_ok(
  format($$UPDATE public.kirim_requests SET actual_goods_sen=4200 WHERE id=%L$$,
         tests.uid('_kirim')),
  NULL, NULL, 'budget cap blocks overspend without a variance');

SELECT lives_ok(
  format($$UPDATE public.kirim_requests SET actual_goods_sen=2800 WHERE id=%L$$,
         tests.uid('_kirim')),
  'spending under the cap is allowed');

-- ...and IS allowed once the requester approves.
INSERT INTO public.price_variances (kirim_id,raised_by,status,original_cap_sen,
  market_price_sen,requested_amount_sen,approved_amount_sen,evidence_photo_path,expires_at)
SELECT tests.uid('_kirim'), tests.uid('rahman'),'APPROVED',3500,4200,4200,4200,
       'receipts/x.jpg', now()+interval '2 hours';

SELECT lives_ok(
  format($$UPDATE public.kirim_requests SET actual_goods_sen=4200 WHERE id=%L$$,
         tests.uid('_kirim')),
  'approved variance permits the overspend');

-- ── C-03: RM250 platform ceiling ───────────────────────────────────────────
SELECT throws_ok(
  $$UPDATE public.kirim_requests SET budget_cap_sen = 25001
    WHERE reference_code='KK-TEST01'$$,
  '23514', NULL, 'budget cap ceiling of RM250 enforced');

-- ── Ledger must balance (deferred to COMMIT) ───────────────────────────────
SELECT throws_ok($$
  DO $x$
  DECLARE t UUID;
  BEGIN
    INSERT INTO internal.ledger_transactions
      (kind,reference_type,reference_id,idempotency_key)
    VALUES ('TEST','test',gen_random_uuid(),'unbalanced-'||gen_random_uuid()::text)
    RETURNING id INTO t;
    PERFORM internal.fn_post(t,'GATEWAY_CLEARING','DEBIT',5000);
    PERFORM internal.fn_post(t,'ESCROW_HELD_GOODS','CREDIT',4000);  -- 1000 short
  END $x$;
$$, NULL, NULL, 'unbalanced ledger transaction cannot commit');

-- ── BR-910: no self-dealing ────────────────────────────────────────────────
SELECT throws_ok(
  format($$INSERT INTO public.reviews (delivery_id,rater_id,ratee_id,rating)
           VALUES (gen_random_uuid(),%L,%L,5)$$,
         tests.uid('aisyah'), tests.uid('aisyah')),
  NULL, NULL, 'ck_no_self_review blocks reviewing yourself');

-- ── Type invariants ────────────────────────────────────────────────────────
SELECT throws_ok(
  format($$INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,
      item_description,category_id,est_weight_grams,dest_address_id,
      origin_node_id,dest_node_id)
    SELECT 'KK-NOBUDGET',%L,'BELI','test',
      (SELECT id FROM ref.categories LIMIT 1),1000,%L,
      (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
      (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu')$$,
    tests.uid('aisyah'), tests.uid('_addr')),
  '23514', NULL, 'BELI without a budget cap is rejected');

SELECT throws_ok(
  $$INSERT INTO internal.ledger_entries (transaction_id,account_id,direction,amount_sen)
    VALUES (gen_random_uuid(),gen_random_uuid(),'DEBIT',0)$$,
  NULL, NULL, 'zero-amount ledger entry rejected');

SELECT * FROM finish();
ROLLBACK;
