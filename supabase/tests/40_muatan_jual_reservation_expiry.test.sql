-- ============================================================================
-- 0050_muatan_jual_reservation_expiry.sql regression tests.
--
-- Three reservations against one lot: a fresh one (A), one old enough to be
-- stale (B), and one that got settled before it could go stale (C).
-- internal.fn_release_stale_lot_reservations() must release exactly B --
-- relieving the lot's own qty_reserved and marking B's own expired_at --
-- leave A and C alone, and rpc_confirm_lot_handover must then refuse B
-- (RESERVATION_EXPIRED) while still accepting A normally.
--
-- ref.compliance_state/ref.feature_gates/ref.category_compliance flipped
-- ON, same pattern as 37_muatan_jual_lot_lifecycle.test.sql's own.
-- ROLLBACK at the end leaves production's rows untouched.
-- ============================================================================
BEGIN;
SELECT plan(9);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

UPDATE ref.compliance_state SET status = 'PRODUCTION_ACTIVE' WHERE id;
UPDATE ref.feature_gates SET enabled = true
 WHERE key IN ('muatan_jual_enabled','muatan_jual_checkout_enabled');
UPDATE ref.category_compliance SET marketplace_enabled = true
 WHERE category_id = (SELECT id FROM ref.categories WHERE slug='kraf');
UPDATE public.carriers SET completed_count = 20 WHERE id = tests.uid('_carrier');

DO $$
DECLARE v_kepayan UUID; v_seller UUID; v_lot UUID;
        v_a JSONB; v_b JSONB; v_c JSONB;
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

  v_lot := (public.rpc_create_lot(
    'Ikan Kering Beluran', 'kraf', 10, 15000, 'lot-receipts/rahman/receipt.jpg', 2500
  )->>'lot_id')::uuid;
  PERFORM public.rpc_attach_lot_to_trip(v_lot, tests.uid('_trip'));
  PERFORM tests.clear_auth();
  INSERT INTO tests.handles(handle,user_id) VALUES ('_lot40', v_lot)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  PERFORM tests.authenticate_as('aisyah');
  v_a := public.rpc_buy_from_lot(v_lot, 2);  -- A: fresh, stays reserved
  v_b := public.rpc_buy_from_lot(v_lot, 3);  -- B: will be backdated -- stale
  v_c := public.rpc_buy_from_lot(v_lot, 1);  -- C: will be settled before going stale
  PERFORM tests.clear_auth();
  INSERT INTO tests.handles(handle,user_id) VALUES
    ('_purchase40a',(v_a->>'purchase_id')::uuid),
    ('_purchase40b',(v_b->>'purchase_id')::uuid),
    ('_purchase40c',(v_c->>'purchase_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  PERFORM tests.authenticate_as('rahman');
  PERFORM public.rpc_confirm_lot_handover((v_c->>'purchase_id')::uuid);
  PERFORM tests.clear_auth();

  -- Backdate B and C past lot_reservation_ttl_hours (24h, seeded default).
  -- C is already settled -- backdating it too proves the sweep skips a
  -- settled row regardless of age, not merely because it's recent.
  UPDATE public.lot_purchases SET created_at = now() - interval '48 hours'
   WHERE id IN ((v_b->>'purchase_id')::uuid, (v_c->>'purchase_id')::uuid);
END $$;

-- ── the sweep ────────────────────────────────────────────────────────────
SELECT is(
  internal.fn_release_stale_lot_reservations(),
  1, 'the sweep releases exactly one stale reservation (B), not the fresh one (A) or the settled one (C)');
SELECT is(
  (SELECT qty_reserved FROM public.carrier_stock_lots WHERE id = tests.uid('_lot40')),
  2::numeric, 'qty_reserved falls back to exactly A''s own qty (2) once B''s 3 is released');
SELECT is(
  (SELECT expired_at IS NOT NULL FROM public.lot_purchases WHERE id = tests.uid('_purchase40b')),
  true, 'B is marked expired');
SELECT is(
  (SELECT expired_at FROM public.lot_purchases WHERE id = tests.uid('_purchase40a')),
  NULL::timestamptz, 'A, still fresh, is untouched');
SELECT is(
  (SELECT expired_at FROM public.lot_purchases WHERE id = tests.uid('_purchase40c')),
  NULL::timestamptz, 'C, already settled, is never marked expired even though it was just as old as B');
SELECT is(
  internal.fn_release_stale_lot_reservations(),
  0, 'running the sweep again releases nothing -- B is already expired, A is still fresh');

-- ── rpc_confirm_lot_handover respects the expiry ────────────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_confirm_lot_handover(%L)$$, tests.uid('_purchase40b')),
  NULL, NULL, 'RESERVATION_EXPIRED: a carrier cannot settle a reservation the sweep already released');
SELECT is(
  (public.rpc_confirm_lot_handover(tests.uid('_purchase40a')))->>'status',
  'SETTLED', 'A, never touched by the sweep, still settles normally');
SELECT tests.clear_auth();
SELECT is(
  (SELECT qty_sold FROM public.carrier_stock_lots WHERE id = tests.uid('_lot40')),
  3::numeric, 'qty_sold reflects both C (1, settled earlier) and A (2, settled just now)');

SELECT * FROM finish();
ROLLBACK;
