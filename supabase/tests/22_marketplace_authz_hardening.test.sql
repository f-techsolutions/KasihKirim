-- ============================================================================
-- P1 final-audit regression: the authorisation matrix, handover code security,
-- risk-hold release, and admin-only refunds (0030_marketplace_authz_hardening
-- plus the surfaces 0027/0028/0029 introduced).
--
-- Two live defects motivated this file, both found by probing the committed
-- implementation rather than by reading it:
--
--   * a stranger could insert a DRAFT PASARAN kirim pointing at ANOTHER
--     buyer's order. It could never be promoted to POSTED, but
--     fn_bridge_order_to_delivery adopted it as "already bridged" -- so
--     pre-seeding one made that order permanently undeliverable;
--
--   * a seller could not open a dispute on their own order. 0027 picked one
--     role from the caller's list and checked it afterwards; sellers almost
--     always also hold `customer`, roles arrive alphabetically, and a seller
--     is not the delivery's requester.
-- ============================================================================
BEGIN;
SELECT plan(39);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('a22_seller',  '+60128882201', ARRAY['customer','seller']);
SELECT tests.create_user('a22_seller2', '+60128882202', ARRAY['customer','seller']);
SELECT tests.create_user('a22_carrier2','+60128882203', ARRAY['customer','carrier']);
SELECT tests.create_user('a22_buyer2',  '+60128882204', ARRAY['customer']);

DO $$
DECLARE v_s UUID; v_s2 UUID; v_c2 UUID; v_cat UUID; v_kep UUID; v_p UUID; v_veh UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kep FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('a22_seller'),'Kedai A22',v_kep,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('a22_seller2'),'Kedai A22b',v_kep,'APPROVED',1000) RETURNING id INTO v_s2;
  INSERT INTO public.carriers (user_id,status,verified_at,float_limit_sen)
  VALUES (tests.uid('a22_carrier2'),'APPROVED',now(),50000) RETURNING id INTO v_c2;

  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur A22',v_cat,1000,500) RETURNING id INTO v_p;

  INSERT INTO tests.handles(handle,user_id) VALUES
    ('_s',v_s),('_s2',v_s2),('_c2',v_c2),('_p',v_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p'),'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 20 WHERE product_id = tests.uid('_p');

-- ── aisyah places and receives an order ───────────────────────────────────
SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 3 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id; END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim', id FROM public.kirim_requests WHERE order_id=tests.uid('_order')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

-- ── STEP 4: the order/kirim link cannot be forged or duplicated ───────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
             item_description,category_id,est_weight_grams,dest_address_id,
             origin_node_id,dest_node_id,order_id)
           SELECT 'KK-FORGE-A22', %L, 'PASARAN','DRAFT','Forged link to another buyer order',
             (SELECT id FROM ref.categories WHERE slug='sayur'), 1000, %L,
             (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
             (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'), %L$$,
          tests.uid('stranger'), tests.uid('_addr'), tests.uid('_order')),
  NULL, NULL,
  'TEST 4a: a stranger cannot insert a marketplace kirim pointing at another buyer''s order');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.kirim_requests WHERE order_id=tests.uid('_order')),
  1, 'TEST 4b: exactly one delivery job exists for the order');
SELECT ok(EXISTS (SELECT 1 FROM pg_indexes
                   WHERE tablename='kirim_requests' AND indexname='ux_kirim_order'),
  'TEST 4c: one-to-one is structural, not a check-then-insert race');
SELECT is(internal.fn_bridge_order_to_delivery(tests.uid('_order')), tests.uid('_kirim'),
  'TEST 4d: bridging the same order again returns the job it already has');
SELECT is((SELECT requester_id FROM public.kirim_requests WHERE id=tests.uid('_kirim')),
  tests.uid('aisyah'), 'TEST 4e: the job belongs to the order''s actual buyer');
SELECT is((SELECT o.seller_id FROM public.orders o WHERE o.id=tests.uid('_order')),
  tests.uid('_s'), 'TEST 4f: the order belongs to the product''s seller');

-- ── carrier assignment ───────────────────────────────────────────────────
SELECT tests.authenticate_as('rahman');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id; END $$;
SELECT tests.clear_auth();

-- ── STEP 5: the authorisation matrix ─────────────────────────────────────
-- carrier: only the assigned one
SELECT tests.authenticate_as('a22_carrier2');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'GO_TO_PICKUP')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 5a: an unrelated carrier cannot move somebody else''s delivery');
SELECT tests.authenticate_as('rahman');
SELECT is((public.rpc_delivery_transition(tests.uid('_delivery'),'GO_TO_PICKUP'))->>'status',
  'AWAITING_PICKUP', 'TEST 5b: the assigned carrier can');

-- seller: issues the pickup code, and only for their own order
SELECT tests.authenticate_as('a22_seller2');
SELECT throws_ok(
  format($$SELECT public.rpc_issue_handover_code(%L,'pickup')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST 5c: another seller cannot be issued this order''s pickup code');

SELECT tests.authenticate_as('a22_seller');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_issue_handover_code(tests.uid('_delivery'),'pickup');
  PERFORM set_config('tests.a22_code', r->>'code', false); END $$;
SELECT matches(current_setting('tests.a22_code'), '^[0-9]{6}$',
  'TEST 5d: the order''s own seller is issued a code');

-- ── STEP 6: handover code security ───────────────────────────────────────
-- a second delivery, to prove a code is bound to the one it was issued for
SELECT tests.authenticate_as('a22_buyer2');
INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
  community_id,landmark_note,nearest_node_id)
SELECT tests.uid('a22_buyer2'),'Rumah2','Buyer2','+60128882204',
  (SELECT id FROM public.communities WHERE name='Kg Kepayan Baru'),
  'Rumah kuning', (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu');
INSERT INTO tests.handles(handle,user_id)
  SELECT '_addr2', id FROM public.addresses WHERE user_id=tests.uid('a22_buyer2')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
INSERT INTO public.carts (user_id) VALUES (tests.uid('a22_buyer2')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 1 FROM public.carts c WHERE c.user_id=tests.uid('a22_buyer2');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_checkout(tests.uid('_addr2'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order2',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id; END $$;
SELECT tests.clear_auth();
SELECT tests.authenticate_as('rahman');
DO $$ DECLARE r JSONB; v_k UUID; BEGIN
  SELECT id INTO v_k FROM public.kirim_requests WHERE order_id=tests.uid('_order2');
  r := public.rpc_accept_offer(tests.uid('_trip'), v_k);
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery2',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id; END $$;

SELECT is((public.rpc_verify_handover_code(
             tests.uid('_delivery2'),'pickup', current_setting('tests.a22_code')))->>'reason',
  'NO_ACTIVE_CODE',
  'TEST 6a: a code issued for one delivery is useless on another');

SELECT tests.authenticate_as('a22_carrier2');
SELECT throws_ok(
  format($$SELECT public.rpc_verify_handover_code(%L,'pickup',%L)$$,
         tests.uid('_delivery'), current_setting('tests.a22_code')),
  NULL, NULL, 'TEST 6b: an unrelated carrier cannot consume this delivery''s code');

-- reissue retires the previous code
SELECT tests.authenticate_as('a22_seller');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_issue_handover_code(tests.uid('_delivery'),'pickup');
  PERFORM set_config('tests.a22_code2', r->>'code', false); END $$;
SELECT isnt(current_setting('tests.a22_code2'), current_setting('tests.a22_code'),
  'TEST 6c: reissuing produces a different code');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.handover_codes
            WHERE delivery_id=tests.uid('_delivery') AND leg='pickup'
              AND consumed_at IS NULL AND locked_at IS NULL),
  1, 'TEST 6d: only one code is live per leg -- the old one is retired');

-- brute force: five wrong attempts lock the code out
SELECT tests.authenticate_as('rahman');
SELECT is((public.rpc_verify_handover_code(tests.uid('_delivery'),'pickup','000001'))->>'verified',
  'false', 'TEST 6e: a wrong code is refused');
SELECT is((public.rpc_verify_handover_code(tests.uid('_delivery'),'pickup','000002'))->>'attempts_left',
  '3', 'TEST 6f: each wrong attempt burns one of the five');
SELECT public.rpc_verify_handover_code(tests.uid('_delivery'),'pickup','000003');
SELECT public.rpc_verify_handover_code(tests.uid('_delivery'),'pickup','000004');
SELECT is((public.rpc_verify_handover_code(tests.uid('_delivery'),'pickup','000005'))->>'reason',
  'LOCKED', 'TEST 6g: the fifth wrong attempt locks the code out');
SELECT is((public.rpc_verify_handover_code(
             tests.uid('_delivery'),'pickup', current_setting('tests.a22_code2')))->>'reason',
  'NO_ACTIVE_CODE',
  'TEST 6h: once locked, even the correct code is dead -- brute force gains nothing');

-- a fresh code verifies once, and only once
SELECT tests.authenticate_as('a22_seller');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_issue_handover_code(tests.uid('_delivery'),'pickup');
  PERFORM set_config('tests.a22_code3', r->>'code', false); END $$;
SELECT tests.authenticate_as('rahman');
SELECT is((public.rpc_verify_handover_code(
             tests.uid('_delivery'),'pickup', current_setting('tests.a22_code3')))->>'verified',
  'true', 'TEST 6i: a fresh code verifies');
SELECT is((public.rpc_verify_handover_code(
             tests.uid('_delivery'),'pickup', current_setting('tests.a22_code3')))->>'reason',
  'NO_ACTIVE_CODE', 'TEST 6j: and cannot be replayed');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.handover_codes WHERE code_hash = current_setting('tests.a22_code3')),
  0, 'TEST 6k: no code is ever stored in plaintext');

-- ── deliver, then the seller disputes their own order ────────────────────
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

-- THE FALSE DENIAL 0027 INTRODUCED: a seller holds `customer` too, and the
-- OPEN_DISPUTE rule permits both. Picking a role before substantiating it
-- refused the seller their own order's dispute.
SELECT tests.authenticate_as('a22_seller');
SELECT is((public.rpc_delivery_transition(tests.uid('_delivery'),'OPEN_DISPUTE'))->>'status',
  'DISPUTED',
  'TEST 5e: a seller who also holds the customer role can dispute their own order');

SELECT tests.authenticate_as('a22_seller2');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'OPEN_DISPUTE')$$, tests.uid('_delivery2')),
  NULL, NULL, 'TEST 5f: a seller cannot act on another seller''s order');

-- The bare transition moves the delivery but files nothing: rpc_open_dispute
-- is what creates the row fn_settlement_blocked_reason actually checks. It
-- accepts a delivery already at DISPUTED, so the buyer can still file.
SELECT tests.authenticate_as('aisyah');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_open_dispute(tests.uid('_delivery'),'damaged',
        'Sayur sampai dalam keadaan rosak dan tidak boleh dimakan');
  INSERT INTO tests.handles(handle,user_id) VALUES ('_dispute',(r->>'dispute_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id; END $$;
SELECT tests.clear_auth();
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')),
  'ESCROW_HELD_BY_DISPUTE', 'TEST 7c: the filed dispute is what freezes the money');

-- ── STEP 7: refunds are admin-only ───────────────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_admin_resolve_dispute(%L,'RESOLVED_REFUND_FULL','mine now',999999)$$,
         tests.uid('_dispute')),
  NULL, NULL, 'TEST 7a: a customer cannot resolve a dispute or name their own refund');
SELECT throws_ok(
  format($$SELECT internal.fn_refund_order(%L, 999999, 'mine now', NULL)$$, tests.uid('_order')),
  NULL, NULL, 'TEST 7b: nor call the refund path directly');

-- ── STEP 9: a cleared risk hold lets settlement proceed ──────────────────
SELECT tests.clear_auth();
SELECT tests.authenticate_as('admin');
SELECT is((public.rpc_admin_resolve_dispute(
             tests.uid('_dispute'),'RESOLVED_REJECTED','claim not upheld',0))->>'delivery_status',
  'DELIVERED',
  'TEST 8a: resolving a dispute returns the delivery to the settlement queue');
SELECT tests.clear_auth();
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'TEST 9a: a rejected dispute releases the hold it placed');

SELECT ok(internal.fn_raise_risk_hold('delivery', tests.uid('_delivery'), 'manual_review', 4)
          IS NOT NULL, 'TEST 9b: a hold can be placed on the delivery itself');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), 'RISK_HOLD',
  'TEST 9c: and it blocks settlement');

UPDATE internal.risk_signals SET resolved_at = now()
 WHERE subject_id = tests.uid('_delivery') AND holds_settlement;
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'TEST 9d: clearing the hold lets settlement proceed when nothing else blocks');
SELECT lives_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('_delivery')),
  'TEST 9e: and settlement then runs');
SELECT cmp_ok(internal.fn_account_balance_sen('SELLER_PAYABLE:'||tests.uid('_s')::text),
  '>', 0::bigint, 'TEST 9f: the seller is paid only after every hold is clear');

-- ── STEP 12: marketplace pricing does not disturb Kirim pricing ──────────
SELECT tests.authenticate_as('aisyah');
DO $$ DECLARE r JSONB; BEGIN
  r := public.rpc_quote_kirim('HANTAR','hasil-laut',2000,
        (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
        (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'));
  PERFORM set_config('tests.a22_kirim_quote', r::text, false); END $$;
SELECT tests.clear_auth();
SELECT cmp_ok((current_setting('tests.a22_kirim_quote')::jsonb->>'delivery_fee_sen')::bigint,
  '>', 0::bigint, 'TEST 12a: a Kirim quote still prices a delivery fee');
-- internal.commission_rules already carried three overlapping platform rows
-- before P1 (0006 inserts three, seed.sql one more); fn_quote_kirim resolves
-- the latest by effective_from. What matters for isolation is that P1 added
-- none and did not change which one wins.
SELECT is((SELECT basis||':'||rate_bps FROM internal.commission_rules
            WHERE party='platform' AND effective_from <= now()
              AND (effective_to IS NULL OR effective_to > now())
            ORDER BY effective_from DESC LIMIT 1),
  'order_total:2500',
  'TEST 12b: the platform commission rule the quote engine resolves is unchanged');
SELECT is((current_setting('tests.a22_kirim_quote')::jsonb->>'commission_sen')::bigint,
  ((current_setting('tests.a22_kirim_quote')::jsonb->>'order_total_sen')::bigint * 2500 / 10000),
  'TEST 12d: a Kirim quote still takes 25% of its own total, exactly as before');
SELECT is((SELECT subject_type FROM internal.quotes
            WHERE id=(SELECT quote_id FROM public.orders WHERE id=tests.uid('_order'))),
  'order', 'TEST 12c: a marketplace quote is labelled order, a Kirim quote is not');

-- ── the control that makes schema `internal` unreachable ────────────────
-- Many pre-P1 internal functions still carry the default PUBLIC EXECUTE
-- grant (fn_post, fn_refund, fn_apply_payment_event among them). They are
-- unreachable because `authenticated` has no USAGE on the schema and
-- config.toml does not expose it to PostgREST. Pinning the USAGE control
-- here so that granting it can never become a silent change.
SELECT ok(NOT has_schema_privilege('authenticated','internal','USAGE'),
  'TEST K16: authenticated has no USAGE on schema internal');
SELECT ok(NOT has_schema_privilege('anon','internal','USAGE'),
  'TEST K17: anon has no USAGE on schema internal');

SELECT * FROM finish();
ROLLBACK;
