-- ============================================================================
-- rpc_record_purchase (0037) — closes the BELI PROCURING dead-end.
-- ============================================================================
BEGIN;
SELECT plan(5);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- The fixture's own BELI kirim (_kirim), budget_cap_sen = 3500, driven to
-- PROCURING directly -- matches 03_state_machine's own style of inserting
-- the delivery at whatever status the test needs rather than replaying every
-- prior transition.
DO $$
DECLARE v_d UUID;
BEGIN
  INSERT INTO public.deliveries (kirim_id,carrier_id,status)
  VALUES (tests.uid('_kirim'), tests.uid('_carrier'), 'PROCURING')
  RETURNING id INTO v_d;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_delivery',v_d)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

-- 1. The customer on this Kirim is not the assigned carrier.
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_record_purchase(%L, 3000)$$, tests.uid('_delivery')),
  NULL, NULL, 'a customer cannot record a purchase');

-- 2. The assigned carrier, within budget, moves PROCURING -> AWAITING_PICKUP.
SELECT tests.authenticate_as('rahman');
SELECT is(
  (SELECT public.rpc_record_purchase(tests.uid('_delivery'), 3200, 'receipts/r1.jpg')->>'status'),
  'AWAITING_PICKUP',
  'recording a within-budget purchase advances the delivery');

-- 3. The write actually landed on kirim_requests -- this RPC is the only
-- path to these three columns, so this is the real regression guard.
SELECT tests.clear_auth();
SELECT is(
  (SELECT actual_goods_sen FROM public.kirim_requests WHERE id = tests.uid('_kirim')),
  3200::bigint,
  'actual_goods_sen is recorded');
SELECT ok(
  (SELECT goods_purchased_at IS NOT NULL FROM public.kirim_requests WHERE id = tests.uid('_kirim')),
  'goods_purchased_at is stamped');

-- 4. The dead end is closed, not turned into a re-openable door: a delivery
-- already past PROCURING rejects a second call.
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_record_purchase(%L, 3200)$$, tests.uid('_delivery')),
  NULL, NULL, 'cannot record a purchase on a delivery no longer PROCURING');

SELECT * FROM finish();
ROLLBACK;
