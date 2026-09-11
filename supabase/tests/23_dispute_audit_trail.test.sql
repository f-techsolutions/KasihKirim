-- ============================================================================
-- Final merge-readiness hardening: the dispute audit trail gap
-- (0032_dispute_audit_trail.sql).
--
-- ref.delivery_transition_rules has always permitted {customer,seller,carrier}
-- to fire DELIVERED --OPEN_DISPUTE--> DISPUTED, but only rpc_open_dispute
-- (customer-only) ever wrote a public.disputes row. A seller or carrier
-- reaching OPEN_DISPUTE through the generic public.rpc_delivery_transition
-- moved the delivery with no row behind it: no category, no description, no
-- audit_logs entry, and -- before this migration -- no settlement block
-- either, since fn_settlement_blocked_reason keys off the ROW, not the
-- status. 0032 makes internal.fn_delivery_transition itself write the row,
-- for every role and every kirim_type, whenever a transition actually lands
-- on DISPUTED.
-- ============================================================================
BEGIN;
SELECT plan(24);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p23_seller',   '+60128882301', ARRAY['customer','seller']);
SELECT tests.create_user('p23_stranger', '+60128882302', ARRAY['customer']);

-- ── a delivered, captured, undisputed marketplace order ────────────────────
DO $$
DECLARE v_s UUID; v_cat UUID; v_kepayan UUID; v_p UUID;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories WHERE slug='sayur';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,commission_bps)
  VALUES (tests.uid('p23_seller'),'Kedai P23',v_kepayan,'APPROVED',1000) RETURNING id INTO v_s;
  INSERT INTO public.products (seller_id,title,category_id,price_sen,weight_grams)
  VALUES (v_s,'Sayur P23',v_cat,1000,500) RETURNING id INTO v_p;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_s',v_s),('_p',v_p)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('admin');
SELECT public.rpc_admin_set_product_status(tests.uid('_p'), 'active');
SELECT tests.clear_auth();
UPDATE public.inventory SET on_hand = 10 WHERE product_id = tests.uid('_p');

SELECT tests.authenticate_as('aisyah');
INSERT INTO public.carts (user_id) VALUES (tests.uid('aisyah')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 2 FROM public.carts c WHERE c.user_id=tests.uid('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim', id FROM public.kirim_requests WHERE order_id=tests.uid('_order')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'GO_TO_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'setup: eligible to settle before anybody disputes it');

-- ── an unrelated user cannot trigger OPEN_DISPUTE at all ───────────────────
SELECT tests.authenticate_as('p23_stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'OPEN_DISPUTE')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST A1: an unrelated user cannot reach OPEN_DISPUTE on this delivery');
SELECT tests.clear_auth();
SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  0, 'TEST A2: the refused attempt creates no dispute row');

-- ── an unrelated seller cannot act on this delivery either ─────────────────
-- Tested while the delivery is still at DELIVERED, so a rejection here is
-- genuinely authorization (STATE_ACTOR_NOT_PERMITTED), not merely the
-- transition no longer being valid once DISPUTED.
SELECT tests.create_user('p23_seller2', '+60128882303', ARRAY['customer','seller']);
SELECT tests.authenticate_as('p23_seller2');
SELECT throws_ok(
  format($$SELECT public.rpc_delivery_transition(%L,'OPEN_DISPUTE')$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST A3: a seller with no relationship to this order cannot dispute it');
SELECT tests.clear_auth();

-- ── the seller raises OPEN_DISPUTE through the bare transition RPC ─────────
-- Not through rpc_open_dispute -- that endpoint is customer-only. This is
-- the path 0030 fixed authorization for and this migration adds a record to.
SELECT tests.authenticate_as('p23_seller');
SELECT is((public.rpc_delivery_transition(tests.uid('_delivery'),'OPEN_DISPUTE'))->>'status',
  'DISPUTED', 'TEST B1: the seller can move their own order''s delivery to DISPUTED');
SELECT tests.clear_auth();

SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  1, 'TEST B2: the bare transition alone leaves exactly one dispute row');
SELECT is((SELECT raised_by FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  tests.uid('p23_seller'), 'TEST B3: attributed to the seller who actually raised it');
SELECT is((SELECT against_id FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  tests.uid('rahman'), 'TEST B4: a seller-raised dispute is routed against the assigned carrier');
SELECT is((SELECT category FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  'other', 'TEST B5: with no free-text field on the bare transition, category defaults sanely');
SELECT ok((SELECT length(description) FROM public.disputes
            WHERE delivery_id=tests.uid('_delivery')) >= 10,
  'TEST B6: a truthful, non-trivial description is recorded even with no caller input');
SELECT is((SELECT refund_sen FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  0::bigint, 'TEST B7: opening a dispute this way still moves no money');
SELECT ok((SELECT holds_escrow FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  'TEST B8: the row holds escrow exactly as a customer-raised one does');
SELECT ok(EXISTS (SELECT 1 FROM audit.audit_logs
                   WHERE action='DISPUTE_OPENED' AND actor_id=tests.uid('p23_seller')
                     AND actor_role='seller'),
  'TEST B9: the seller''s own filing is in the audit trail, attributed to them');

-- ── settlement is blocked immediately, with no separate customer filing ────
-- This is the actual gap closed: before 0032 the bare transition alone froze
-- nothing, because fn_settlement_blocked_reason checks the ROW.
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')),
  'ESCROW_HELD_BY_DISPUTE',
  'TEST C1: the seller''s own transition now blocks settlement by itself');
SELECT throws_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('_delivery')),
  NULL, NULL, 'TEST C2: settling a seller-disputed delivery is refused outright');

-- ── the buyer can still file after the fact ─────────────────────────────────
-- rpc_open_dispute accepts a delivery already at DISPUTED. The row the
-- seller's bare transition created is found and returned rather than
-- duplicated -- category/description stay the seller-path defaults from B5/B6
-- (a documented limitation, not a financial one: nothing here moves money
-- either way, and the buyer's own filing is still visible in delivery_events).
SELECT tests.authenticate_as('aisyah');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_open_dispute(tests.uid('_delivery'),'damaged',
        'Sayur sampai dalam keadaan rosak dan tidak boleh dimakan');
  PERFORM set_config('tests.p23_dispute_id', r->>'dispute_id', false);
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery')),
  1, 'TEST E1: the buyer''s filing on an already-disputed delivery adds no second row');
SELECT is((SELECT raised_by FROM public.disputes
            WHERE id = current_setting('tests.p23_dispute_id')::uuid),
  tests.uid('p23_seller'),
  'TEST E2: the row still credits the party who actually raised it first');
SELECT ok(EXISTS (SELECT 1 FROM audit.audit_logs
                   WHERE action='DISPUTE_ALSO_RAISED' AND actor_id=tests.uid('aisyah')
                     AND entity_id=current_setting('tests.p23_dispute_id')::uuid),
  'TEST E3: the buyer''s own filing still leaves an audit trace, even with no second row');

-- ── resolving returns it to the settlement queue, exactly as before ─────────
SELECT tests.authenticate_as('admin');
SELECT is((public.rpc_admin_resolve_dispute(
             current_setting('tests.p23_dispute_id')::uuid,
             'RESOLVED_REJECTED','claim not upheld',0))->>'delivery_status',
  'DELIVERED', 'TEST F1: resolving the dispute returns the delivery to DELIVERED');
SELECT tests.clear_auth();
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery')), NULL,
  'TEST F2: settlement is unblocked once the dispute is resolved');

-- ── a carrier-raised dispute routes against the requester ──────────────────
SELECT lives_ok(
  format($$SELECT internal.fn_settle_delivery(%L)$$, tests.uid('_delivery')),
  'setup: settle the now-clean delivery so a fresh one is needed for the carrier case');

SELECT tests.create_user('p23_buyer2', '+60128882304', ARRAY['customer']);
DO $$
DECLARE v_addr UUID; BEGIN
  INSERT INTO public.addresses
    (user_id,label,recipient_name,recipient_phone,community_id,landmark_note,
     line1,nearest_node_id,is_default)
    SELECT tests.uid('p23_buyer2'),label,recipient_name,recipient_phone,community_id,
           landmark_note,line1,nearest_node_id,true
      FROM public.addresses WHERE id = tests.uid('_addr')
  RETURNING id INTO v_addr;
  INSERT INTO tests.handles(handle,user_id) VALUES ('_addr2',v_addr)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT tests.authenticate_as('p23_buyer2');
INSERT INTO public.carts (user_id) VALUES (tests.uid('p23_buyer2')) ON CONFLICT DO NOTHING;
INSERT INTO public.cart_items (cart_id,product_id,quantity)
  SELECT c.id, tests.uid('_p'), 1 FROM public.carts c WHERE c.user_id=tests.uid('p23_buyer2');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_checkout(tests.uid('_addr2'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_order2',(r->'orders'->0->>'order_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO tests.handles(handle,user_id)
  SELECT '_kirim2', id FROM public.kirim_requests WHERE order_id=tests.uid('_order2')
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim2'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery2',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery2'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery2'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery2'),'GO_TO_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery2'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery2'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery2'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery2'),'CONFIRM_DELIVERY');

-- the assigned carrier disputes their own delivery
SELECT is((public.rpc_delivery_transition(tests.uid('_delivery2'),'OPEN_DISPUTE'))->>'status',
  'DISPUTED', 'TEST G1: the assigned carrier can dispute their own delivery');
SELECT tests.clear_auth();
SELECT is((SELECT against_id FROM public.disputes WHERE delivery_id=tests.uid('_delivery2')),
  tests.uid('p23_buyer2'), 'TEST G2: a carrier-raised dispute is routed against the requester');
SELECT is(internal.fn_settlement_blocked_reason(tests.uid('_delivery2')),
  'ESCROW_HELD_BY_DISPUTE', 'TEST G3: the carrier''s own transition blocks settlement too');

SELECT * FROM finish();
ROLLBACK;
