-- ============================================================================
-- KasihKirim — 0027_order_delivery_bridge.sql   (P1-D, P1-F, P1-J, P1-K)
--
-- The missing link. public.kirim_requests has carried order_id and the
-- ck_pasaran_has_order constraint since 0001, ref.delivery_transition_rules
-- has carried the full PASARAN chain since the first seed, and 0024 taught
-- settlement how to pay a marketplace order out -- but nothing ever created a
-- PASARAN kirim, so none of it could run. rpc_create_kirim never sets
-- order_id, which ck_pasaran_has_order makes a hard stop.
--
-- This migration closes the loop, reusing the existing delivery state machine
-- rather than adding a second one. No new delivery status is introduced; in
-- particular there is still no ACCEPTED.
--
--   ORDER CREATED -> PAYMENT INTENT -> DELIVERY CREATED (POSTED, on the board)
--   -> CARRIER ASSIGNED (rpc_accept_offer -> MATCHED) -> SELLER HANDOVER
--   -> PICKED_UP -> IN_TRANSIT -> DELIVERED (+ POD, + COD captured)
--   -> CONFIRM_RECEIPT or 48h AUTO_SETTLE -> SETTLED -> order SETTLED
--
-- Three further things this fixes, each found in the P1 audit:
--
--   * rpc_accept_offer priced COD from the delivery quote's total. For a
--     marketplace order the carrier collects the whole order -- goods and
--     carriage -- so the quote total understates the cash by the goods value.
--   * internal.fn_allocate_order_payment (0024) had no caller outside the
--     test suite. It is wired to carrier assignment, which is the first
--     moment every payee is known.
--   * public.rpc_delivery_transition checked that the caller HOLDS a role the
--     transition permits, but never that they are the party on this delivery.
--     Any account with the customer role could CONFIRM_RECEIPT on a stranger's
--     delivery and trigger settlement of somebody else's money.
-- ============================================================================

-- ── 1. Order -> delivery job ────────────────────────────────────────────────
/** Creates the PASARAN kirim that carries a marketplace order, and posts it
 *  to the board so a carrier can accept it.
 *
 *  Every physical attribute is read back from the quote's input_snapshot --
 *  the same snapshot fn_quote_order_delivery priced -- so the job that gets
 *  carried can never differ from the job that was charged for.
 *
 *  Idempotent: a second call returns the kirim that already exists. */
CREATE OR REPLACE FUNCTION internal.fn_bridge_order_to_delivery(p_order UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o public.orders; q internal.quotes; v_kirim UUID; v_ref TEXT;
  v_desc TEXT; v_addr UUID; v_expires TIMESTAMPTZ;
BEGIN
  SELECT id INTO v_kirim FROM public.kirim_requests WHERE order_id = p_order LIMIT 1;
  IF v_kirim IS NOT NULL THEN RETURN v_kirim; END IF;

  SELECT * INTO o FROM public.orders WHERE id = p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF o.quote_id IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_PRICED'; END IF;
  IF COALESCE(o.discount_sen,0) <> 0 THEN RAISE EXCEPTION 'DISCOUNT_POLICY_UNDEFINED'; END IF;

  SELECT * INTO q FROM internal.quotes WHERE id = o.quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;

  v_addr := (o.address_snapshot->>'id')::uuid;
  IF v_addr IS NULL THEN RAISE EXCEPTION 'ORDER_ADDRESS_MISSING'; END IF;

  -- item_description is CHECKed BETWEEN 3 AND 500 characters.
  SELECT left(string_agg(oi.quantity || ' x ' || oi.title_snapshot, ', '
                         ORDER BY oi.title_snapshot), 480)
    INTO v_desc
    FROM public.order_items oi WHERE oi.order_id = p_order;
  v_desc := COALESCE(NULLIF(trim(v_desc),''), 'Pesanan ' || o.reference_code);
  IF length(v_desc) < 3 THEN v_desc := 'Pesanan ' || o.reference_code; END IF;

  v_ref := 'KK-' || to_char(now(),'YYMM') || '-'
           || lpad(nextval('internal.kirim_reference_seq')::text, 6, '0');
  v_expires := now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                         WHERE key='kirim_board_ttl_hours') || ' hours')::interval;

  INSERT INTO public.kirim_requests (
    reference_code, requester_id, kirim_type, status, item_description, category_id,
    est_weight_grams, volume_cm3, handling_flags, dest_address_id,
    origin_node_id, dest_node_id, quote_id, delivery_fee_sen, commission_sen,
    total_escrow_sen, payment_method, order_id, expires_at)
  VALUES (
    v_ref, o.buyer_id, 'PASARAN', 'POSTED', v_desc,
    (q.input_snapshot->>'category')::uuid,
    (q.input_snapshot->>'weight_g')::int,
    (q.input_snapshot->>'volume_cm3')::int,
    ARRAY(SELECT jsonb_array_elements_text(q.input_snapshot->'flags'))::ref.handling_flag[],
    v_addr,
    (q.input_snapshot->>'origin')::uuid,
    (q.input_snapshot->>'dest')::uuid,
    q.id, q.delivery_fee_sen, q.commission_sen,
    o.total_sen, 'COD', p_order, v_expires)
  RETURNING id INTO v_kirim;

  UPDATE internal.quotes SET consumed_at = now() WHERE id = q.id AND consumed_at IS NULL;
  RETURN v_kirim;
END $$;

-- The delivery job is created the moment the protected-payment record opens.
-- It cannot wait for capture: fn_allocate_order_payment needs a delivery (for
-- the carrier and agent legs) and capture needs the allocations, so the
-- ordering delivery -> allocation -> capture is forced by the money, not by
-- convenience. Under COD the customer pays the carrier on the doorstep, so
-- "payment held" is a claim recorded here and cash recorded at DELIVERED.
CREATE OR REPLACE FUNCTION internal.fn_create_order_payment_intent(p_order UUID)
RETURNS internal.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.orders; pay internal.payments; v_methods JSONB;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF o.total_sen <= 0 THEN RAISE EXCEPTION 'ORDER_TOTAL_INVALID'; END IF;

  SELECT value INTO v_methods FROM ref.app_config WHERE key = 'payment_methods_enabled';
  IF v_methods IS NULL OR NOT (v_methods @> '["COD"]'::jsonb) THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_NOT_ENABLED';
  END IF;

  SELECT * INTO pay FROM internal.payments
   WHERE reference_type = 'order' AND reference_id = p_order
   ORDER BY created_at DESC LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO internal.payments (
      reference_type, reference_id, payer_id, provider, provider_ref,
      method, amount_sen, status, status_precedence, idempotency_key)
    VALUES (
      'order', p_order, o.buyer_id, 'cod', o.reference_code,
      'COD', o.total_sen, 'COD_PENDING',
      internal.fn_status_precedence('COD_PENDING'), 'order-intent:'||p_order::text)
    RETURNING * INTO pay;

    UPDATE public.orders
       SET status = 'PENDING_PAYMENT', payment_method = 'COD', updated_at = now()
     WHERE id = p_order;
  END IF;

  PERFORM internal.fn_bridge_order_to_delivery(p_order);
  RETURN pay;
END $$;

-- ── 2. COD capture for a marketplace order ──────────────────────────────────
/** Records the cash the carrier collected at the door.
 *
 *  internal.fn_record_cod_collection (0004) credits the whole amount to
 *  ESCROW_HELD_DELIVERY, which is right for a Kirim -- there is no seller.
 *  A marketplace order's goods share has to land in ESCROW_HELD_GOODS instead,
 *  because that is the account settlement debits for the SELLER leg. Kirim's
 *  own function is untouched; this is the marketplace's equivalent.
 *
 *  Idempotent three times over: cod_collections is UNIQUE on delivery_id, the
 *  ledger transaction's idempotency_key is UNIQUE and deliberately shares the
 *  'capture:<payment>' namespace with fn_apply_payment_event so cash and a
 *  webhook can never both capture the same payment, and an already-captured
 *  payment returns immediately. */
CREATE OR REPLACE FUNCTION internal.fn_capture_order_cod(p_delivery UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  d public.deliveries; k public.kirim_requests; pay internal.payments;
  v_txn UUID; v_cod UUID;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;
  IF k.kirim_type <> 'PASARAN' OR k.order_id IS NULL THEN RETURN; END IF;

  SELECT * INTO pay FROM internal.payments
   WHERE reference_type = 'order' AND reference_id = k.order_id
   ORDER BY created_at DESC LIMIT 1
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_MISSING'; END IF;

  -- Prepaid money arrives through the webhook path, not the doorstep.
  IF pay.method <> 'COD' THEN RETURN; END IF;
  IF internal.fn_status_precedence(pay.status)
     >= internal.fn_status_precedence('CAPTURED') THEN RETURN; END IF;

  INSERT INTO internal.cod_collections (delivery_id, carrier_id, amount_sen, collected_at)
  VALUES (p_delivery, d.carrier_id, pay.amount_sen, now())
  ON CONFLICT (delivery_id) DO NOTHING
  RETURNING id INTO v_cod;

  IF v_cod IS NOT NULL THEN
    -- ck_carrier_exposure (BR-908) fires here if this breaches the float limit.
    UPDATE public.carriers SET cod_held_sen = cod_held_sen + pay.amount_sen
     WHERE id = d.carrier_id;
  END IF;

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('PAYMENT_CAPTURE','order', k.order_id, 'capture:'||pay.id::text,
          'COD collected for '||k.reference_code)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_txn;

  IF v_txn IS NOT NULL THEN
    -- The carrier owes KasihKirim the cash until they remit it.
    PERFORM internal.fn_post(v_txn,'CARRIER_CASH_RECEIVABLE:'||d.carrier_id,'DEBIT', pay.amount_sen);
    -- Same split settlement will later release, so the two legs describe the
    -- same money in the same two accounts.
    PERFORM internal.fn_split_order_capture(v_txn, pay.id, pay.amount_sen);
  END IF;

  UPDATE internal.payments
     SET status='CAPTURED', status_precedence=internal.fn_status_precedence('CAPTURED'),
         updated_at=now()
   WHERE id = pay.id;

  UPDATE public.orders SET status='PAID', updated_at=now()
   WHERE id = k.order_id AND status <> 'SETTLED';
END $$;

-- ── 3. Marketplace hooks on the shared state machine ────────────────────────
-- internal.fn_delivery_transition is reproduced from 0014 with three added
-- branches, every one of them guarded on kirim_type = 'PASARAN'. A Kirim runs
-- through this function exactly as it did before.
CREATE OR REPLACE FUNCTION internal.fn_delivery_transition(
  p_delivery UUID, p_event TEXT, p_actor UUID, p_role ref.user_role,
  p_idem TEXT DEFAULT NULL, p_meta JSONB DEFAULT '{}')
RETURNS ref.kirim_status LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.deliveries; k public.kirim_requests; rule ref.delivery_transition_rules;
BEGIN
  IF p_idem IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.delivery_events WHERE idempotency_key = p_idem) THEN
    SELECT status INTO d.status FROM public.deliveries WHERE id=p_delivery;
    RETURN d.status;                                   -- replay: no second effect
  END IF;

  SELECT * INTO d FROM public.deliveries WHERE id=p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id=d.kirim_id;

  SELECT * INTO rule FROM ref.delivery_transition_rules
   WHERE from_status=d.status AND event=p_event;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION: % from %', p_event, d.status;
  END IF;
  IF NOT (p_role = ANY(rule.allowed_roles)) THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;
  IF NOT (k.kirim_type = ANY(rule.applies_to_types)) THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION: not applicable to %', k.kirim_type;
  END IF;
  IF rule.requires_proof AND NOT EXISTS (
      SELECT 1 FROM public.proofs pf
       WHERE pf.delivery_id = p_delivery AND pf.leg = rule.proof_leg) THEN
    RAISE EXCEPTION 'PROOF_REQUIRED: % leg', rule.proof_leg;
  END IF;

  UPDATE public.deliveries SET
    status = rule.to_status,
    picked_up_at  = CASE WHEN rule.to_status='PICKED_UP' THEN now() ELSE picked_up_at END,
    delivered_at  = CASE WHEN rule.to_status='DELIVERED' THEN now() ELSE delivered_at END,
    pickup_proof_quality = CASE WHEN rule.proof_leg='pickup'
      THEN (SELECT quality FROM public.proofs WHERE delivery_id=p_delivery AND leg='pickup')
      ELSE pickup_proof_quality END,
    dropoff_proof_quality = CASE WHEN rule.proof_leg='dropoff'
      THEN (SELECT quality FROM public.proofs WHERE delivery_id=p_delivery AND leg='dropoff')
      ELSE dropoff_proof_quality END,
    recipient_confirmed_at = CASE WHEN p_event='CONFIRM_RECEIPT' THEN now()
                                  ELSE recipient_confirmed_at END,
    settlement_due_at = CASE WHEN rule.to_status='DELIVERED'
      THEN now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                     WHERE key='settlement_window_hours')||' hours')::interval
      ELSE settlement_due_at END,
    updated_at = now()
  WHERE id = p_delivery;

  UPDATE public.kirim_requests SET status=rule.to_status, updated_at=now() WHERE id=k.id;

  INSERT INTO public.delivery_events
    (delivery_id, from_status, to_status, event, actor_id, actor_role, source,
     idempotency_key, metadata)
  VALUES (p_delivery, d.status, rule.to_status, p_event, p_actor, p_role,
          CASE WHEN p_role::text LIKE 'admin\_%' THEN 'admin' ELSE 'app' END,
          p_idem, p_meta);

  -- ── marketplace-only branches ────────────────────────────────────────────
  IF k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL THEN
    -- Custody has passed: the reservation becomes a sale.
    IF rule.to_status = 'PICKED_UP' THEN
      PERFORM internal.fn_commit_order_stock(k.order_id);
    END IF;

    -- The doorstep is where COD cash enters the ledger. It must happen before
    -- settlement, which will only release money that was actually captured.
    IF rule.to_status = 'DELIVERED' THEN
      PERFORM internal.fn_capture_order_cod(p_delivery);
      UPDATE public.orders SET status='FULFILLED', updated_at=now()
       WHERE id = k.order_id AND status NOT IN ('SETTLED','REFUNDED','PARTIALLY_REFUNDED');
    END IF;

    -- The order never happened: give the stock back, void the claim.
    IF rule.to_status = 'CANCELLED' THEN
      PERFORM internal.fn_release_order_stock(k.order_id, 'order_released');
      UPDATE internal.payment_allocations a
         SET status='CANCELLED', updated_at=now()
       WHERE a.order_id = k.order_id AND a.status='HELD';
      UPDATE public.orders SET status='CANCELLED', updated_at=now()
       WHERE id = k.order_id AND status NOT IN ('SETTLED','REFUNDED','PARTIALLY_REFUNDED');
    END IF;
  END IF;

  -- BR-907: recipient confirmation is the primary escrow release trigger.
  IF p_event = 'CONFIRM_RECEIPT' THEN
    PERFORM internal.fn_settle_delivery(p_delivery);
  END IF;

  RETURN rule.to_status;
END $$;

-- ── 4. Carrier assignment ───────────────────────────────────────────────────
-- Reproduced from 0009 with a PASARAN branch. The Kirim path -- float check,
-- capacity reservation, procurement advance, COD from the quote -- is
-- byte-identical to what it was.
CREATE OR REPLACE FUNCTION public.rpc_accept_offer(
  p_trip UUID, p_kirim UUID, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_carrier UUID := authz.my_carrier_id();
  k public.kirim_requests; q internal.quotes; o public.orders;
  v_res UUID; v_delivery UUID; v_advance BIGINT; v_cod BIGINT; pay internal.payments;
BEGIN
  IF v_carrier IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = p_kirim FOR UPDATE;
  IF NOT FOUND OR k.status <> 'POSTED' THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION';
  END IF;
  IF k.requester_id = auth.uid() THEN RAISE EXCEPTION 'SELF_DEALING'; END IF;

  v_advance := COALESCE(k.budget_cap_sen, 0);
  IF EXISTS (SELECT 1 FROM public.carriers c WHERE c.id = v_carrier
             AND c.cod_held_sen + c.procurement_advance_sen + v_advance > c.float_limit_sen)
  THEN RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED'; END IF;

  v_res := internal.fn_reserve_capacity(
    p_trip, p_kirim, k.est_weight_grams, k.volume_cm3, 1);

  PERFORM set_config('kasihkirim.capacity_sync', 'on', true);
  UPDATE public.trip_reservations SET status='CONFIRMED', expires_at=NULL
   WHERE id = v_res;

  SELECT * INTO q FROM internal.quotes WHERE id = k.quote_id;

  -- A marketplace carrier collects the whole order at the door -- goods and
  -- carriage. The delivery quote covers carriage alone, so using its total
  -- would understate the cash in the carrier's hand by the goods value.
  IF k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL THEN
    SELECT * INTO o FROM public.orders WHERE id = k.order_id;
    v_cod := CASE WHEN k.payment_method='COD' THEN COALESCE(o.total_sen,0) ELSE 0 END;
  ELSE
    v_cod := CASE WHEN k.payment_method='COD' THEN COALESCE(q.total_sen,0) ELSE 0 END;
  END IF;

  INSERT INTO public.deliveries (kirim_id, trip_id, carrier_id, reservation_id,
    requester_id, status, cod_amount_sen, carrier_earning_sen, platform_fee_sen)
  VALUES (p_kirim, p_trip, v_carrier, v_res,
    k.requester_id, 'MATCHED', v_cod,
    COALESCE(q.delivery_fee_sen,0) - COALESCE(q.commission_sen,0),
    COALESCE(q.commission_sen,0))
  RETURNING id INTO v_delivery;

  UPDATE public.carriers SET procurement_advance_sen = procurement_advance_sen + v_advance
   WHERE id = v_carrier;
  UPDATE public.kirim_requests SET status='MATCHED', updated_at=now() WHERE id=p_kirim;

  INSERT INTO public.delivery_events (delivery_id, from_status, to_status, event,
    actor_id, actor_role, source, idempotency_key)
  VALUES (v_delivery, 'POSTED','MATCHED','ACCEPT_OFFER', auth.uid(),'carrier','app',
          p_idempotency_key);

  -- Carrier assignment is the first moment every payee is known, so it is the
  -- earliest point the allocation can be declared. Nothing is credited here;
  -- the rows record who is owed what, and settlement is what pays them.
  IF k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL THEN
    SELECT * INTO pay FROM internal.payments
     WHERE reference_type='order' AND reference_id=k.order_id
     ORDER BY created_at DESC LIMIT 1;
    IF FOUND THEN
      PERFORM internal.fn_allocate_order_payment(pay.id, v_delivery);
    END IF;
    UPDATE public.orders SET status='READY_FOR_PICKUP', updated_at=now()
     WHERE id = k.order_id AND status = 'PENDING_PAYMENT';
  END IF;

  RETURN jsonb_build_object('delivery_id', v_delivery, 'reservation_id', v_res,
                            'status','MATCHED');
END $$;

-- ── 5. Transitions require being a party to the delivery, not just a role ───
-- P1-K. rpc_delivery_transition picked whichever role the caller holds that
-- the rule permits, and stopped there. Holding the customer role is not the
-- same as being THIS delivery's customer: without the check below, any
-- signed-in customer could CONFIRM_RECEIPT a stranger's delivery and release
-- a stranger's escrow. Same for a carrier transitioning a delivery that is
-- not theirs.
--
-- Agent and admin roles are operational and stay unrestricted here: agents
-- work hub-wide by design, and admin authority is already the escape hatch
-- the rules grant them.
CREATE OR REPLACE FUNCTION public.rpc_delivery_transition(
  p_delivery UUID, p_event TEXT,
  p_idempotency_key TEXT DEFAULT NULL, p_meta JSONB DEFAULT '{}')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_role ref.user_role; v_new ref.kirim_status; v_roles TEXT[];
  v_uid UUID := auth.uid(); d public.deliveries; k public.kirim_requests;
BEGIN
  v_roles := authz.user_roles();
  IF array_length(v_roles,1) IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT r::ref.user_role INTO v_role
  FROM unnest(v_roles) r
  JOIN public.deliveries dd ON dd.id = p_delivery
  JOIN ref.delivery_transition_rules t
    ON t.from_status = dd.status AND t.event = p_event
  WHERE r::ref.user_role = ANY(t.allowed_roles)
  LIMIT 1;

  IF v_role IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  IF v_role = 'customer' AND k.requester_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;
  IF v_role = 'carrier' AND d.carrier_id IS DISTINCT FROM authz.my_carrier_id() THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;
  IF v_role = 'seller' AND NOT EXISTS (
      SELECT 1 FROM public.orders o
      JOIN public.sellers s ON s.id = o.seller_id
      WHERE o.id = k.order_id AND s.user_id = v_uid) THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  v_new := internal.fn_delivery_transition(
    p_delivery, p_event, v_uid, v_role, p_idempotency_key, p_meta);

  RETURN jsonb_build_object(
    'status', v_new,
    'next_events', COALESCE((SELECT jsonb_agg(event) FROM ref.delivery_transition_rules
                             WHERE from_status = v_new), '[]'::jsonb));
END $$;

-- ── 6. Grants ───────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.fn_bridge_order_to_delivery(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_capture_order_cod(UUID)        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_create_order_payment_intent(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_delivery_transition(UUID,TEXT,UUID,ref.user_role,TEXT,JSONB)
  FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_accept_offer(UUID,UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_offer(UUID,UUID,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_delivery_transition(UUID,TEXT,TEXT,JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delivery_transition(UUID,TEXT,TEXT,JSONB) TO authenticated;

COMMENT ON FUNCTION internal.fn_bridge_order_to_delivery(UUID) IS
  'Creates the PASARAN kirim that carries a marketplace order. Idempotent. '
  'Physical attributes are read back from the priced quote, never re-supplied.';
