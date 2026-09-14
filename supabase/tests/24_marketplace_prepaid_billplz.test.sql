-- ============================================================================
-- PHASE 2 / P2-A: prepaid payment intent + Billplz bill lifecycle
-- (0034_marketplace_prepaid_billplz.sql).
--
-- Covers what 0034 actually changes: rpc_checkout/fn_create_order_payment_intent
-- taking a non-COD method and refusing to bridge to delivery until the money
-- actually arrives; rpc_prepare_billplz_bill and rpc_record_billplz_bill's
-- ownership, state and trust-boundary checks; fn_apply_payment_event's new
-- bridge-on-capture and release-on-failure branches for a marketplace order.
-- COD's own behaviour is already covered by 17_marketplace_checkout.test.sql
-- and is untouched here -- this file exercises only the new, non-COD path.
-- ============================================================================
BEGIN;
SELECT plan(45);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

-- Production stays COD-only by default (0002); this file deliberately opts a
-- single test transaction into FPX to exercise the new path, and everything
-- rolls back at the end.
UPDATE ref.app_config SET value = '["COD","FPX"]'::jsonb
 WHERE key = 'payment_methods_enabled';

SELECT tests.create_user('p24_seller', '+60128882401', ARRAY['customer','seller']);
SELECT tests.create_user('p24_buyer2', '+60128882402', ARRAY['customer']);

DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID; v_p2 UUID; v_addr2 UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p24_seller'),'Kedai P24',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Ikan P24',v_cat,5000,800) RETURNING id INTO v_p;
  -- A second, isolated product for the gateway-failure scenario (section I),
  -- so its inventory counts cannot be muddled by the other orders above it.
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Udang P24',v_cat,3000,600) RETURNING id INTO v_p2;

  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
      community_id,landmark_note,nearest_node_id)
    SELECT tests.uid('p24_buyer2'),label,recipient_name,recipient_phone,community_id,
           landmark_note,nearest_node_id
      FROM public.addresses WHERE id = tests.uid('_addr')
  RETURNING id INTO v_addr2;

  INSERT INTO tests.handles(handle,user_id)
  VALUES ('_s',v_s),('_p',v_p),('_p2',v_p2),('_addr2',v_addr2)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p'), 'active');
SELECT public.rpc_admin_set_product_status(tests.uid('_p2'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20 WHERE product_id IN (tests.uid('_p'), tests.uid('_p2'));

-- ── A. checkout with a non-COD method opens a payment but does not bridge ──
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');

DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'), NULL, 'FPX');
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
  PERFORM set_config('tests.p24_response', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT count(*)::int FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  1, 'TEST A1: checkout opens exactly one payment intent');
SELECT is((SELECT method::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'FPX', 'TEST A2: the intent carries the requested method');
SELECT is((SELECT status::text FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'PENDING', 'TEST A3: a prepaid intent starts PENDING, not COD_PENDING');
SELECT is((SELECT provider FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'pending', 'TEST A4: no gateway has been contacted yet');
SELECT ok((SELECT provider_ref IS NULL FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')),
  'TEST A5: no bill exists yet either');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('_order')),
  'PENDING_PAYMENT', 'TEST A6: the order still moves off CREATED');
SELECT is((SELECT count(*)::int FROM public.kirim_requests
            WHERE order_id=tests.uid('_order')),
  0, 'TEST A7: THE FIX -- a prepaid order is NOT bridged to a carrier at checkout');

-- ── B. guard rails on fn_create_order_payment_intent ───────────────────────
-- Called directly against the order section A already created (whose payment
-- intent already exists) rather than through a fresh checkout: the method
-- checks run before the "intent already exists" replay check, so this
-- exercises the guards in isolation without touching the cart at all.
SELECT throws_ok(
  format($$SELECT internal.fn_create_order_payment_intent(%L,'BOGUS')$$, tests.uid('_order')),
  NULL, NULL, 'TEST B1: an unrecognised payment method is refused outright');
SELECT throws_ok(
  format($$SELECT internal.fn_create_order_payment_intent(%L,'CARD')$$, tests.uid('_order')),
  NULL, NULL, 'TEST B2: a real method that is not in payment_methods_enabled is refused too');
SELECT is((SELECT count(*)::int FROM internal.payments
            WHERE reference_type='order' AND reference_id=tests.uid('_order')), 1,
  'TEST B3: neither refused attempt created a second payment intent for the order');

-- ── C. rpc_prepare_billplz_bill: ownership and shape ───────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_prepare_billplz_bill(%L)$$, tests.uid('_order')),
  NULL, NULL, 'TEST C1: a stranger cannot prepare a bill for someone else''s order');
SELECT tests.clear_auth();

SELECT tests.authenticate_as('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_prepare_billplz_bill(tests.uid('_order'));
  PERFORM set_config('tests.p24_prep', r::text, false);
END $$;
SELECT tests.clear_auth();

SELECT is((current_setting('tests.p24_prep')::jsonb->>'already_created')::boolean,
  false, 'TEST C2: no bill has been created yet');
SELECT is((current_setting('tests.p24_prep')::jsonb->>'amount_sen')::bigint,
  (SELECT total_sen FROM public.orders WHERE id=tests.uid('_order')),
  'TEST C3: the amount to bill is the server-computed order total');
SELECT is(current_setting('tests.p24_prep')::jsonb->>'mobile', '+60128880001',
  'TEST C4: the buyer''s own phone is offered as the mobile field');
SELECT is(current_setting('tests.p24_prep')::jsonb->>'name', 'Pelanggan',
  'TEST C5: with no full_name on the profile, the name falls back sanely');
SELECT is(current_setting('tests.p24_prep')::jsonb->>'reference_code',
  (SELECT reference_code FROM public.orders WHERE id=tests.uid('_order')),
  'TEST C6: the reference shown to the gateway is the order''s own reference code');

-- ── D. rpc_record_billplz_bill is a service_role-only trust boundary ──────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_record_billplz_bill(%L,'bill_hack','https://evil.example/x')$$,
         (current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid),
  NULL, NULL, 'TEST D1: a signed-in buyer cannot record their own bill result');
SELECT tests.clear_auth();

DO $$
BEGIN
  PERFORM internal.fn_record_billplz_bill(
    (current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid,
    'bill_p24_1', 'https://www.billplz-sandbox.com/bills/bill_p24_1');
END $$;

SELECT is((SELECT provider FROM internal.payments
            WHERE id=(current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid),
  'billplz', 'TEST D2: the payment is now attributed to billplz');
SELECT is((SELECT provider_ref FROM internal.payments
            WHERE id=(current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid),
  'bill_p24_1', 'TEST D3: the bill id the gateway returned is recorded');
SELECT is((SELECT checkout_url FROM internal.payments
            WHERE id=(current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid),
  'https://www.billplz-sandbox.com/bills/bill_p24_1',
  'TEST D4: the hosted payment page URL is recorded');

-- a losing retry (or a client asking again) must not overwrite what won
DO $$
BEGIN
  PERFORM internal.fn_record_billplz_bill(
    (current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid,
    'bill_p24_SHOULD_NOT_STICK', 'https://www.billplz-sandbox.com/bills/should-not-stick');
END $$;
SELECT is((SELECT provider_ref FROM internal.payments
            WHERE id=(current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid),
  'bill_p24_1', 'TEST D5: a second write to an already-recorded bill is a no-op');

-- ── E. a retry of rpc_prepare_billplz_bill is idempotent ──────────────────
SELECT tests.authenticate_as('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_prepare_billplz_bill(tests.uid('_order'));
  PERFORM set_config('tests.p24_prep2', r::text, false);
END $$;
SELECT tests.clear_auth();
SELECT is((current_setting('tests.p24_prep2')::jsonb->>'already_created')::boolean,
  true, 'TEST E1: a second call reports the bill already exists');
SELECT is(current_setting('tests.p24_prep2')::jsonb->>'checkout_url',
  'https://www.billplz-sandbox.com/bills/bill_p24_1',
  'TEST E2: it hands back the same URL rather than minting a second bill');

-- ── F. capture: the webhook path funds escrow and bridges to delivery ─────
INSERT INTO internal.webhook_events (provider,provider_event_id,signature_valid,payload)
VALUES ('billplz','evt_p24_paid',true,'{"status":"paid","reference":"bill_p24_1"}');

SELECT lives_ok(
  $$SELECT internal.fn_apply_payment_event('billplz','evt_p24_paid')$$,
  'TEST F1: applying the paid event succeeds');

SELECT is((SELECT status::text FROM internal.payments
            WHERE id=(current_setting('tests.p24_prep')::jsonb->>'payment_id')::uuid),
  'SUCCEEDED', 'TEST F2: the payment reaches SUCCEEDED');
SELECT ok(EXISTS (SELECT 1 FROM public.kirim_requests
                   WHERE order_id=tests.uid('_order') AND kirim_type='PASARAN'),
  'TEST F3: THE FIX -- capture is what finally bridges a prepaid order to delivery');
SELECT is((SELECT count(*)::int FROM internal.ledger_transactions
            WHERE kind='PAYMENT_CAPTURE' AND reference_type='order'
              AND reference_id=tests.uid('_order')),
  1, 'TEST F4: exactly one capture transaction is posted');
SELECT is(
  (SELECT SUM(CASE WHEN e.direction='DEBIT' THEN e.amount_sen ELSE -e.amount_sen END)::bigint
     FROM internal.ledger_entries e
     JOIN internal.ledger_transactions t ON t.id=e.transaction_id
    WHERE t.reference_type='order' AND t.reference_id=tests.uid('_order')
      AND t.kind='PAYMENT_CAPTURE'),
  0::bigint, 'TEST F5: INVARIANT -- the capture transaction balances (debits = credits)');

-- replaying the same event a second time must not double-bridge or double-post
INSERT INTO internal.webhook_events (provider,provider_event_id,signature_valid,payload)
VALUES ('billplz','evt_p24_paid_replay',true,'{"status":"paid","reference":"bill_p24_1"}');
SELECT lives_ok(
  $$SELECT internal.fn_apply_payment_event('billplz','evt_p24_paid_replay')$$,
  'TEST F6: a same-status replay under a new event id is accepted, not an error');
SELECT is((SELECT count(*)::int FROM public.kirim_requests WHERE order_id=tests.uid('_order')),
  1, 'TEST F7: still exactly one delivery job -- the bridge stayed idempotent');
SELECT is((SELECT count(*)::int FROM internal.ledger_transactions
            WHERE kind='PAYMENT_CAPTURE' AND reference_type='order'
              AND reference_id=tests.uid('_order')),
  1, 'TEST F8: still exactly one capture transaction -- no money moved twice');

-- ── G. a payment already captured cannot be re-billed ──────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_prepare_billplz_bill(%L)$$, tests.uid('_order')),
  NULL, NULL, 'TEST G1: a succeeded payment refuses a fresh bill (not PENDING/INITIATED)');
SELECT tests.clear_auth();

-- ── H. a COD payment is never billed through Billplz ───────────────────────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 1 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order_cod',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT throws_ok(
  format($$SELECT public.rpc_prepare_billplz_bill(%L)$$, tests.uid('_order_cod')),
  NULL, NULL, 'TEST H1: a COD order''s payment cannot be pushed through Billplz');
SELECT tests.clear_auth();

-- ── I. failure at the gateway releases stock and cancels the order ────────
-- Its own product (_p2), untouched by anything above, so the before/after
-- reservation counts are exact rather than a running tally across sections.
SELECT tests.authenticate_as('p24_buyer2');
INSERT INTO public.carts (user_id) VALUES (tests.uid('p24_buyer2')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p2'), 2 FROM public.carts c WHERE c.user_id=tests.uid('p24_buyer2');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr2'), NULL, 'FPX');
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order_f',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p2')),
  2, 'setup: the failed order''s 2 units are reserved');

SELECT tests.authenticate_as('p24_buyer2');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_prepare_billplz_bill(tests.uid('_order_f'));
  PERFORM set_config('tests.p24_prep_f', r::text, false);
END $$;
SELECT tests.clear_auth();
DO $$
BEGIN
  PERFORM internal.fn_record_billplz_bill(
    (current_setting('tests.p24_prep_f')::jsonb->>'payment_id')::uuid,
    'bill_p24_fail', 'https://www.billplz-sandbox.com/bills/bill_p24_fail');
END $$;

INSERT INTO internal.webhook_events (provider,provider_event_id,signature_valid,payload)
VALUES ('billplz','evt_p24_failed',true,'{"status":"failed","reference":"bill_p24_fail"}');
SELECT lives_ok(
  $$SELECT internal.fn_apply_payment_event('billplz','evt_p24_failed')$$,
  'TEST I1: applying a failed event succeeds (it is a valid outcome, not an error)');

SELECT is((SELECT status::text FROM internal.payments
            WHERE id=(current_setting('tests.p24_prep_f')::jsonb->>'payment_id')::uuid),
  'FAILED', 'TEST I2: the payment reaches FAILED');
SELECT is((SELECT status::text FROM public.orders WHERE id=tests.uid('_order_f')),
  'CANCELLED', 'TEST I3: THE FIX -- a failed prepaid order is cancelled, not left dangling');
SELECT is((SELECT reserved FROM public.inventory WHERE product_id=tests.uid('_p2')),
  0, 'TEST I4: THE FIX -- the reserved stock is given back');
SELECT is((SELECT on_hand FROM public.inventory WHERE product_id=tests.uid('_p2')),
  20, 'TEST I5: on_hand is untouched -- the goods never left in the first place');
SELECT ok(EXISTS (SELECT 1 FROM public.inventory_movements
                   WHERE product_id=tests.uid('_p2') AND reference_id=tests.uid('_order_f')
                     AND reason='payment_failed'),
  'TEST I6: the release is itself audit-visible');
SELECT is((SELECT count(*)::int FROM public.kirim_requests WHERE order_id=tests.uid('_order_f')),
  0, 'TEST I7: a never-funded order is never handed to a carrier');
SELECT is((SELECT count(*)::int FROM internal.ledger_transactions
            WHERE reference_type='order' AND reference_id=tests.uid('_order_f')),
  0, 'TEST I8: a failed payment moves no money in either direction');

-- ── J. rpc_get_payment_status: buyer can poll, nobody else can ────────────
SELECT tests.authenticate_as('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_get_payment_status(tests.uid('_order'));
  PERFORM set_config('tests.p24_status', r::text, false);
END $$;
SELECT tests.clear_auth();
SELECT is(current_setting('tests.p24_status')::jsonb->>'status', 'SUCCEEDED',
  'TEST J1: the buyer sees their own payment''s current status');
SELECT is(current_setting('tests.p24_status')::jsonb->>'checkout_url',
  'https://www.billplz-sandbox.com/bills/bill_p24_1',
  'TEST J2: and the checkout URL that was used');

SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_get_payment_status(%L)$$, tests.uid('_order')),
  NULL, NULL, 'TEST J3: a stranger cannot poll someone else''s payment status');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
