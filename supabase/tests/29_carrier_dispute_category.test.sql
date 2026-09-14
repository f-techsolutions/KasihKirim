-- ============================================================================
-- rpc_open_carrier_dispute (0039_carrier_dispute_category.sql).
--
-- ref.delivery_transition_rules has always let a carrier fire DELIVERED
-- --OPEN_DISPUTE--> DISPUTED, but this client never offered any way to reach
-- it: no button existed at all (unlike the seller's old bare-transition
-- button, which at least existed and just defaulted category='other'). This
-- is the carrier-facing counterpart to rpc_open_dispute/rpc_open_seller_dispute
-- (0038): a real category and description, authorized the same way
-- rpc_delivery_transition (0030) already authorizes a carrier's own delivery.
-- ============================================================================
BEGIN;
SELECT plan(13);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

SELECT tests.create_user('p39_carrier2', '+60128883901', ARRAY['customer','carrier']);

-- ── a delivered Kirim (Hantar), not a marketplace order -- proves this
-- path works for every kirim_type, unlike the seller-only rpc_open_seller_dispute ──
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_accept_offer(tests.uid('_trip'), tests.uid('_kirim'));
  INSERT INTO tests.handles(handle,user_id) VALUES ('_delivery39',(r->>'delivery_id')::uuid)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;
SELECT tests.clear_auth();
INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
VALUES (tests.uid('_delivery39'),'pickup','QR','STRONG',now()),
       (tests.uid('_delivery39'),'dropoff','QR','STRONG',now());
SELECT tests.authenticate_as('rahman');
SELECT public.rpc_delivery_transition(tests.uid('_delivery39'),'START_PROCUREMENT');
SELECT public.rpc_record_purchase(tests.uid('_delivery39'), 3000);
SELECT public.rpc_delivery_transition(tests.uid('_delivery39'),'CONFIRM_PICKUP');
SELECT public.rpc_delivery_transition(tests.uid('_delivery39'),'DEPART');
SELECT public.rpc_delivery_transition(tests.uid('_delivery39'),'START_DELIVERY');
SELECT public.rpc_delivery_transition(tests.uid('_delivery39'),'CONFIRM_DELIVERY');
SELECT tests.clear_auth();

-- ── a carrier with no relationship to this delivery cannot use it ─────────
SELECT tests.authenticate_as('p39_carrier2');
SELECT throws_ok(
  format($$SELECT public.rpc_open_carrier_dispute(%L,'damaged','Barang sampai dalam keadaan rosak')$$,
         tests.uid('_delivery39')),
  NULL, NULL, 'TEST 1: an unrelated carrier cannot dispute someone else''s delivery');
SELECT tests.clear_auth();

-- ── validation mirrors rpc_open_dispute/rpc_open_seller_dispute's own ─────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_open_carrier_dispute(%L,'not_a_real_category','Barang sampai dalam keadaan rosak')$$,
         tests.uid('_delivery39')),
  NULL, NULL, 'TEST 2: an invalid category is refused, not silently coerced');
SELECT throws_ok(
  format($$SELECT public.rpc_open_carrier_dispute(%L,'damaged','too short')$$,
         tests.uid('_delivery39')),
  NULL, NULL, 'TEST 3: a too-short description is refused');
SELECT tests.clear_auth();

-- ── the assigned carrier raises a real, non-'other' category ──────────────
SELECT tests.authenticate_as('rahman');
DO $$
DECLARE r JSONB;
BEGIN
  r := public.rpc_open_carrier_dispute(tests.uid('_delivery39'),'payment',
        'Bayaran tunai semasa penghantaran tidak mencukupi jumlah sepatutnya');
  PERFORM set_config('tests.p39_dispute_id', r->>'dispute_id', false);
END $$;
SELECT tests.clear_auth();

SELECT is((SELECT status FROM public.deliveries WHERE id=tests.uid('_delivery39')),
  'DISPUTED'::ref.kirim_status, 'TEST 4: the delivery moves to DISPUTED');
SELECT is((SELECT count(*)::int FROM public.disputes WHERE delivery_id=tests.uid('_delivery39')),
  1, 'TEST 5: exactly one dispute row is created');
SELECT is((SELECT category FROM public.disputes
            WHERE id=current_setting('tests.p39_dispute_id')::uuid),
  'payment', 'TEST 6: the carrier''s real category is recorded, not the ''other'' default');
SELECT is((SELECT description FROM public.disputes
            WHERE id=current_setting('tests.p39_dispute_id')::uuid),
  'Bayaran tunai semasa penghantaran tidak mencukupi jumlah sepatutnya',
  'TEST 7: the carrier''s own free-text description is recorded verbatim');
SELECT is((SELECT raised_by FROM public.disputes
            WHERE id=current_setting('tests.p39_dispute_id')::uuid),
  tests.uid('rahman'), 'TEST 8: attributed to the carrier who actually raised it');
SELECT is((SELECT against_id FROM public.disputes
            WHERE id=current_setting('tests.p39_dispute_id')::uuid),
  tests.uid('aisyah'), 'TEST 9: a carrier-raised dispute is routed against the requester');
SELECT ok((SELECT holds_escrow FROM public.disputes
            WHERE id=current_setting('tests.p39_dispute_id')::uuid),
  'TEST 10: the row holds escrow exactly as a customer-raised one does');
SELECT ok(EXISTS (SELECT 1 FROM audit.audit_logs
                   WHERE action='DISPUTE_OPENED' AND actor_id=tests.uid('rahman')
                     AND actor_role='carrier'),
  'TEST 11: the carrier''s own filing is in the audit trail, attributed to them');

-- ── the same carrier cannot re-file while it is still open ────────────────
SELECT tests.authenticate_as('rahman');
SELECT throws_ok(
  format($$SELECT public.rpc_open_carrier_dispute(%L,'wrong_item','Barang yang dihantar salah sepenuhnya')$$,
         tests.uid('_delivery39')),
  NULL, NULL, 'TEST 12: the same carrier cannot file a second dispute while theirs is still open');
SELECT tests.clear_auth();

-- ── resolving returns it to the settlement queue, exactly as the other two paths' does ──
SELECT tests.authenticate_as('admin');
SELECT is((public.rpc_admin_resolve_dispute(
             current_setting('tests.p39_dispute_id')::uuid,
             'RESOLVED_REJECTED','claim not upheld',0))->>'delivery_status',
  'DELIVERED', 'TEST 13: resolving the dispute returns the delivery to DELIVERED');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
