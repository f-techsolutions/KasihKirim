-- ============================================================================
-- 0045_kongsi_untung_promotions.sql regression tests.
--
-- 0006_carrier_commerce.sql already created public.promotions,
-- public.promotion_attributions, and internal.fn_attribute_promotion (rate
-- from internal.commission_rules, posts its own ledger transaction) -- but
-- nothing ever called any of it, and no RPC let a client create a code or
-- record a click. This file drives the whole loop this migration actually
-- wires up: create a code, open it (recording a click), buy through
-- rpc_checkout (which stamps the order with the resolved click), run the
-- order to settlement (mirroring 18_order_delivery_lifecycle.test.sql), and
-- check the promoter is paid a capped share of the platform's own
-- commission -- plus the payout/withdrawal path and the pre-existing
-- self-referral trigger, neither ever exercised by any test until now.
--
-- kongsi_untung_enabled is on in production (0052_enable_kongsi_untung.sql).
-- This file pins the gate off first to prove the disabled path still works,
-- then flips it back on for the rest of the run. ROLLBACK at the end means
-- production is never actually touched.
-- ============================================================================
BEGIN;
SET LOCAL app.settings.bank_account_enc_key = 'pgtap-local-test-key-do-not-use-in-production';
SELECT plan(35);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p35_promoter', '+60128881935', ARRAY['customer']);
SELECT tests.create_user('p35_seller',   '+60128881936', ARRAY['customer','seller']);
SELECT tests.create_user('p35_thief',    '+60128881937', ARRAY['customer']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID; v_kk UUID; v_addr_promoter UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p35_seller'),'Kedai P35',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P35',v_cat,1000,500) RETURNING id INTO v_p;

  -- The promoter needs their own delivery address to check out with (the
  -- fixture's own '_addr' belongs to aisyah).
  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
    community_id,landmark_note,nearest_node_id)
  VALUES (tests.uid('p35_promoter'),'Rumah','P35 Promoter','+60128881935',
    v_kepayan,'Sebelah kedai', v_kk)
  RETURNING id INTO v_addr_promoter;

  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_s35',v_s),('_p35',v_p),('_addr_promoter',v_addr_promoter)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p35'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20 WHERE product_id = tests.uid('_p35');

-- ── production default: the gate is OFF ─────────────────────────────────────
-- 0052_enable_kongsi_untung.sql turned this on in production (and therefore
-- in every fresh migration replay, this fixture included), so pin it back
-- off here to keep exercising the disabled path below. ROLLBACK at the end
-- leaves production's row untouched.
UPDATE ref.feature_gates SET enabled = false WHERE key = 'kongsi_untung_enabled';
SELECT tests.authenticate_as('p35_promoter');
SELECT throws_ok(
  format($$SELECT public.rpc_create_promotion('product', %L)$$, tests.uid('_p35')),
  NULL, NULL, 'rpc_create_promotion refuses while kongsi_untung_enabled is off');
SELECT throws_ok(
  $$SELECT public.rpc_open_promotion('ANYCODE1')$$,
  NULL, NULL, 'rpc_open_promotion refuses while kongsi_untung_enabled is off');
SELECT throws_ok(
  $$SELECT public.rpc_add_bank_account('MBB','1111111111','P35 Promoter')$$,
  NULL, NULL, 'a plain customer still cannot add a bank account while the gate is off');
SELECT tests.clear_auth();

-- Flip the gate on for the rest of this file. Never applied for real --
-- ROLLBACK at the end leaves production's ref.feature_gates row untouched.
UPDATE ref.feature_gates SET enabled = true WHERE key = 'kongsi_untung_enabled';

-- ── rpc_create_promotion ─────────────────────────────────────────────────────
SELECT tests.authenticate_as('p35_promoter');
SELECT throws_ok(
  $$SELECT public.rpc_create_promotion('lot', gen_random_uuid())$$,
  NULL, NULL, 'an invalid subject_type is rejected');
SELECT throws_ok(
  format($$SELECT public.rpc_create_promotion('product', %L)$$, gen_random_uuid()),
  NULL, NULL, 'a nonexistent product cannot be promoted');

DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_create_promotion('product', tests.uid('_p35'));
  PERFORM set_config('tests.p35_code', r->>'code', false);
END $$;
SELECT matches(current_setting('tests.p35_code'), '^[0-9A-F]{8}$',
  'a created promotion code is an 8-char uppercase hex string');
SELECT is(
  (public.rpc_create_promotion('product', tests.uid('_p35')))->>'code',
  current_setting('tests.p35_code'),
  'creating a promotion for the same subject again is idempotent -- same code');
SELECT is(
  (SELECT count(*)::int FROM public.promotions WHERE promoter_id = tests.uid('p35_promoter')),
  1, 'exactly one promotions row exists despite two create calls');
SELECT tests.clear_auth();

-- ── rpc_open_promotion ───────────────────────────────────────────────────────
SELECT is(
  (public.rpc_open_promotion('NOSUCHCODE'))->>'found', 'false',
  'opening an unknown code reports found:false rather than raising');
SELECT is(
  (public.rpc_open_promotion(current_setting('tests.p35_code')))->>'found', 'true',
  'opening the real code (even signed out) resolves it');
SELECT is(
  (public.rpc_open_promotion(current_setting('tests.p35_code')))->'subject'->>'title',
  'Sayur P35', 'the resolved subject is the promoted product');
SELECT is(
  (SELECT click_count FROM public.promotions WHERE code = current_setting('tests.p35_code')),
  2, 'two signed-out opens both counted toward click_count');
SELECT is(
  (SELECT count(*)::int FROM public.promotion_clicks),
  0, 'a signed-out open records no click (there is no buyer to attribute to)');

-- The promoter opening their own link is counted, but never recorded as a
-- click against themselves (self-referral is enforced further down too).
SELECT tests.authenticate_as('p35_promoter');
SELECT public.rpc_open_promotion(current_setting('tests.p35_code'));
SELECT tests.clear_auth();
SELECT is(
  (SELECT count(*)::int FROM public.promotion_clicks WHERE buyer_id = tests.uid('p35_promoter')),
  0, 'the promoter opening their own code records no self-click');

-- aisyah opens the link -- the click FR-421's 7-day window measures from.
SELECT tests.authenticate_as('aisyah');
SELECT public.rpc_open_promotion(current_setting('tests.p35_code'));
SELECT tests.clear_auth();
SELECT is(
  (SELECT count(*)::int FROM public.promotion_clicks WHERE buyer_id = tests.uid('aisyah')),
  1, 'aisyah opening the link records exactly one click');

-- ── checkout resolves the click into orders.promo_code ──────────────────────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p35'), 3 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_order35',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT is(
  (SELECT promo_code FROM public.orders WHERE id = tests.uid('_order35')),
  current_setting('tests.p35_code'),
  'the order is stamped with the promoter''s code at checkout');

INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim35', id FROM public.kirim_requests WHERE order_id=tests.uid('_order35')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

-- ── run the order to settlement (mirrors 18_order_delivery_lifecycle) ───────
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim35'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery35',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery35'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery35'),'dropoff','QR','STRONG',now());

SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery35'),'GO_TO_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery35'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery35'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery35'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery35'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('aisyah');
SELECT is(
  (public.rpc_delivery_transition(tests.uid('_delivery35'),'CONFIRM_RECEIPT'))->>'status',
  'COMPLETED', 'the order reaches COMPLETED, triggering settlement');
SELECT tests.clear_auth();

-- ── settlement attributed and paid the promoter, capped per commission_rules ─
-- internal.fn_attribute_promotion (0006) posts the ledger entries
-- synchronously at attribution time and never itself transitions the
-- attribution row's own status away from its DEFAULT 'PENDING' -- nothing
-- in 0006 ever does (SETTLED/REVERSED exist on the CHECK for a future
-- admin/reconciliation action). The money has already moved by this point
-- regardless of this row's status; PROMOTER_PAYABLE below is what's
-- actually authoritative and withdrawable.
SELECT is(
  (SELECT status FROM public.promotion_attributions WHERE order_id = tests.uid('_order35')),
  'PENDING', 'the attribution row itself stays PENDING -- 0006 never sweeps it to SETTLED');
SELECT is(
  (SELECT promoter_sen FROM public.promotion_attributions WHERE order_id = tests.uid('_order35')),
  (SELECT LEAST(plat.amount_sen * cr.rate_bps / 10000, cr.max_commission_sen)
     FROM internal.payment_allocations plat, internal.commission_rules cr
    WHERE plat.order_id = tests.uid('_order35') AND plat.allocation_type = 'PLATFORM'
      AND cr.context = 'promoter' AND cr.effective_to IS NULL),
  'the promoter is credited exactly the rate/cap internal.commission_rules already defines');
SELECT is(
  internal.fn_account_balance_sen('PROMOTER_PAYABLE:'||tests.uid('p35_promoter')::text),
  (SELECT promoter_sen FROM public.promotion_attributions WHERE order_id = tests.uid('_order35')),
  'the promoter''s ledger balance matches the attributed amount');
SELECT is(
  internal.fn_account_balance_sen('PLATFORM_COMMISSION'),
  (SELECT amount_sen FROM internal.payment_allocations
    WHERE order_id = tests.uid('_order35') AND allocation_type = 'PLATFORM')
  - (SELECT promoter_sen FROM public.promotion_attributions WHERE order_id = tests.uid('_order35')),
  'the platform keeps its commission minus exactly what the promoter earned (FR-422)');
SELECT is(
  (SELECT status FROM public.orders WHERE id = tests.uid('_order35')),
  'SETTLED', 'the underlying order still reaches SETTLED normally');

-- ── self-referral: the promoter earns nothing from their own purchase ──────
SELECT tests.authenticate_as('p35_promoter');
INSERT INTO public.carts (user_id) VALUES (tests.uid('p35_promoter')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p35'), 1 FROM public.carts c WHERE c.user_id=tests.uid('p35_promoter');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr_promoter'));
  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_order35_self',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
SELECT is(
  (SELECT promo_code FROM public.orders WHERE id = tests.uid('_order35_self')),
  NULL, 'checkout never attaches a promoter''s own code to their own order');

-- 0006's own trigger (never exercised by any test until now): a direct
-- attempt to attribute a promoter to their own purchase is blocked outright.
SELECT throws_ok(
  format(
    $$INSERT INTO public.promotion_attributions
        (promotion_id, buyer_id, order_id, order_total_sen, platform_commission_sen, promoter_sen)
      VALUES (%L, %L, %L, 100, 10, 10)$$,
    (SELECT id FROM public.promotions WHERE code = current_setting('tests.p35_code')),
    tests.uid('p35_promoter'), tests.uid('_order35_self')),
  NULL, NULL, '0006''s self-referral trigger blocks a promoter attributed to their own purchase');

-- ── rpc_my_promotions dashboard ──────────────────────────────────────────────
SELECT tests.authenticate_as('p35_promoter');
SELECT is(
  (public.rpc_my_promotions()->'promotions'->0->>'code'),
  current_setting('tests.p35_code'), 'the dashboard lists the promoter''s own code');
SELECT is(
  (public.rpc_my_promotions()->'promotions'->0->>'pending_sen')::bigint,
  (SELECT promoter_sen FROM public.promotion_attributions WHERE order_id = tests.uid('_order35')),
  'the dashboard reports aisyah''s order under pending_sen -- the row''s own status never leaves PENDING');
SELECT is(
  (public.rpc_my_promotions()->>'available_sen')::bigint,
  (SELECT promoter_sen FROM public.promotion_attributions WHERE order_id = tests.uid('_order35')),
  'the full settled amount is available to withdraw (nothing requested yet)');

-- ── promoter payouts ─────────────────────────────────────────────────────────
SELECT is(
  (public.rpc_add_bank_account('MBB','9999999999','P35 Promoter'))->>'account_no_last4',
  '9999', 'a plain customer CAN add a bank account once kongsi_untung is enabled');

INSERT INTO tests.handles (handle, user_id)
SELECT '_bank35', id FROM public.rpc_my_bank_accounts() LIMIT 1
ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;

SELECT throws_ok(
  format($$SELECT public.rpc_request_withdrawal('promoter', %L, 999999999)$$, tests.uid('_bank35')),
  NULL, NULL, 'requesting more than the promoter''s available balance is refused');
SELECT is(
  (public.rpc_request_withdrawal('promoter', tests.uid('_bank35'),
     (SELECT promoter_sen FROM public.promotion_attributions WHERE order_id = tests.uid('_order35'))
   ))->>'status',
  'REQUESTED', 'the promoter can withdraw exactly their settled earnings');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('p35_promoter');
SELECT is(
  (SELECT payee_type FROM public.rpc_my_payouts() LIMIT 1),
  'promoter', 'rpc_my_payouts surfaces the promoter''s own withdrawal request');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('admin');
SELECT ok(
  EXISTS (SELECT 1 FROM public.rpc_admin_list_payouts() WHERE payee_type='promoter'),
  'the admin payout queue shows the promoter''s request');
SELECT is(
  (SELECT payee_label FROM public.rpc_admin_list_payouts() WHERE payee_type='promoter'),
  (SELECT COALESCE(full_name, display_name) FROM public.profiles WHERE id = tests.uid('p35_promoter')),
  'the promoter''s payout is labelled with their profile name, not a raw id');
SELECT tests.clear_auth();

-- ── seller-subject promotions are validated the same way ────────────────────
DO $$
DECLARE v_unapproved UUID;
BEGIN
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p35_thief'),'Not Approved Yet',
    (SELECT id FROM public.communities WHERE name='Kg Kepayan Baru'),'SUBMITTED',1000)
  RETURNING id INTO v_unapproved;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_unapproved_seller', v_unapproved)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('p35_promoter');
SELECT throws_ok(
  format($$SELECT public.rpc_create_promotion('seller', %L)$$, tests.uid('_unapproved_seller')),
  NULL, NULL, 'a not-yet-approved seller cannot be promoted');
SELECT is(
  (public.rpc_create_promotion('seller', tests.uid('_s35')))->>'subject_type',
  'seller', 'an APPROVED seller can be promoted directly');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
