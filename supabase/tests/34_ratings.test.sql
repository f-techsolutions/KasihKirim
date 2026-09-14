-- ============================================================================
-- 0044_ratings.sql regression tests.
--
-- Drives a HANTAR kirim (simpler than BELI here -- no PROCURING/
-- record_purchase leg) all the way from POSTED through to COMPLETED via the
-- real transition RPCs, exactly the path 18_order_delivery_lifecycle.test.sql
-- already proved reaches COMPLETED (CONFIRM_RECEIPT), then exercises
-- rpc_submit_review against it: party validation, the double-blind reveal,
-- rating_avg/rating_count aggregation on both profiles and carriers, the
-- edit window, and the direct-INSERT grant revocation.
-- ============================================================================
BEGIN;
SELECT plan(18);
SELECT tests.clear_auth();
SELECT tests.seed_fixture();

DO $$
DECLARE
  v_cat UUID; v_beluran UUID; v_kk UUID; v_kirim UUID; v_delivery UUID; r JSONB;
BEGIN
  SELECT id INTO v_cat     FROM ref.categories  WHERE slug='hasil-laut';
  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';

  -- Inserted directly as postgres, same as tests.seed_fixture's own kirim
  -- row -- kirim_insert (0030) only allows a client to insert status='DRAFT',
  -- and this needs to start life already POSTED to be accept_offer-able.
  INSERT INTO public.kirim_requests (
    reference_code,requester_id,kirim_type,status,item_description,category_id,
    est_weight_grams,origin_address_id,dest_address_id,origin_node_id,dest_node_id,
    total_escrow_sen)
  VALUES (
    'KK-RATE01',tests.uid('aisyah'),'HANTAR','POSTED','Sekotak barang',v_cat,
    1000,tests.uid('_addr'),tests.uid('_addr'),v_beluran,v_kk,3000)
  RETURNING id INTO v_kirim;

  PERFORM tests.authenticate_as('rahman');
  r := public.rpc_accept_offer(tests.uid('_trip'), v_kirim);
  v_delivery := (r->>'delivery_id')::uuid;
  PERFORM tests.clear_auth();

  INSERT INTO public.proofs (delivery_id,leg,method,quality,captured_at)
  VALUES (v_delivery,'pickup','QR','STRONG',now()),
         (v_delivery,'dropoff','QR','STRONG',now());

  PERFORM tests.authenticate_as('rahman');
  PERFORM public.rpc_delivery_transition(v_delivery,'GO_TO_PICKUP');
  PERFORM public.rpc_delivery_transition(v_delivery,'CONFIRM_PICKUP');
  PERFORM public.rpc_delivery_transition(v_delivery,'DEPART');
  PERFORM public.rpc_delivery_transition(v_delivery,'START_DELIVERY');
  PERFORM public.rpc_delivery_transition(v_delivery,'CONFIRM_DELIVERY');
  PERFORM tests.clear_auth();

  PERFORM tests.authenticate_as('aisyah');
  PERFORM public.rpc_delivery_transition(v_delivery,'CONFIRM_RECEIPT');
  PERFORM tests.clear_auth();

  INSERT INTO tests.handles(handle,user_id) VALUES ('_kirim2', v_kirim), ('_delivery2', v_delivery)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;

SELECT is((SELECT status::text FROM public.deliveries WHERE id=tests.uid('_delivery2')),
  'COMPLETED', 'setup: the delivery reaches COMPLETED via the real transition chain');

-- ── party validation ─────────────────────────────────────────────────────────
SELECT tests.authenticate_as('stranger');
SELECT throws_ok(
  format($$SELECT public.rpc_submit_review(%L, 5, 'nice')$$, tests.uid('_delivery2')),
  NULL, NULL, 'a user who was not a party to the delivery cannot review it');
SELECT tests.clear_auth();

-- ── rating bounds are checked before anything else ──────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_submit_review(%L, 6, NULL)$$, tests.uid('_delivery2')),
  NULL, NULL, 'a rating outside 1-5 is refused');

-- ── direct table INSERT is no longer possible ───────────────────────────────
SELECT throws_ok(
  format(
    $$INSERT INTO public.reviews (delivery_id,rater_id,ratee_id,rating) VALUES (%L,%L,%L,5)$$,
    tests.uid('_delivery2'), tests.uid('aisyah'), tests.uid('rahman')),
  NULL, NULL, 'a direct INSERT is refused now that rpc_submit_review is the only write path');

-- ── first review: not yet visible, no aggregate effect ──────────────────────
SELECT is(
  (public.rpc_submit_review(tests.uid('_delivery2'), 5, 'Great carrier!'))->>'is_visible',
  'false', 'the first review of a pair is not visible yet');
SELECT tests.clear_auth();

SELECT is(
  (SELECT rating_count FROM public.profiles WHERE id = tests.uid('rahman')),
  0, 'the ratee''s public rating is untouched while only one side has rated');

-- ── second review (the carrier rating the customer back): double-blind reveal ─
SELECT tests.authenticate_as('rahman');
SELECT is(
  (public.rpc_submit_review(tests.uid('_delivery2'), 4, 'Good customer'))->>'is_visible',
  'true', 'the second review reveals immediately');
SELECT tests.clear_auth();

SELECT is(
  (SELECT is_visible FROM public.reviews
    WHERE delivery_id = tests.uid('_delivery2') AND rater_id = tests.uid('aisyah')),
  true, 'the first review is also revealed the moment the second lands');

SELECT is(
  (SELECT rating_avg FROM public.profiles WHERE id = tests.uid('rahman')),
  5.00::numeric, 'rahman (rated 5 by aisyah) has his public rating aggregated');
SELECT is(
  (SELECT rating_count FROM public.profiles WHERE id = tests.uid('rahman')),
  1, 'rahman''s rating_count reflects the one visible review about him');
SELECT is(
  (SELECT rating_avg FROM public.carriers WHERE id = tests.uid('_carrier')),
  5.00::numeric, 'the carrier row''s own rating_avg is aggregated the same way');
SELECT is(
  (SELECT rating_avg FROM public.profiles WHERE id = tests.uid('aisyah')),
  4.00::numeric, 'aisyah (rated 4 by rahman) has her public rating aggregated too');

-- ── editing within the window changes the aggregate, not the visibility ────
SELECT tests.authenticate_as('aisyah');
SELECT is(
  (public.rpc_submit_review(tests.uid('_delivery2'), 3, 'Actually just okay'))->>'is_visible',
  'true', 'editing an already-revealed review keeps it visible');
SELECT tests.clear_auth();
SELECT is(
  (SELECT rating_avg FROM public.profiles WHERE id = tests.uid('rahman')),
  3.00::numeric, 'editing the review recomputes the ratee''s aggregate to the new rating');

-- ── the edit window closes ───────────────────────────────────────────────────
UPDATE public.reviews SET editable_until = now() - interval '1 hour'
 WHERE delivery_id = tests.uid('_delivery2') AND rater_id = tests.uid('aisyah');
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$SELECT public.rpc_submit_review(%L, 1, 'too late')$$, tests.uid('_delivery2')),
  NULL, NULL, 'editing after the window has closed is refused');
SELECT tests.clear_auth();

-- ── the sweep reveals a one-sided review whose window has closed ───────────
UPDATE public.reviews SET is_visible = false WHERE delivery_id = tests.uid('_delivery2');
UPDATE public.reviews SET editable_until = now() - interval '1 minute'
 WHERE delivery_id = tests.uid('_delivery2') AND rater_id = tests.uid('aisyah');
SELECT is(
  (internal.fn_sweep_reveal_reviews()->>'revealed')::int, 1,
  'the sweep reveals exactly the one review whose window has closed');
SELECT is(
  (SELECT is_visible FROM public.reviews
    WHERE delivery_id = tests.uid('_delivery2') AND rater_id = tests.uid('aisyah')),
  true, 'the swept review is now visible');

-- ── the sweep is never reachable from a client ──────────────────────────────
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  $$SELECT internal.fn_sweep_reveal_reviews()$$,
  NULL, NULL, 'a client can never call the sweep function directly (schema internal)');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
