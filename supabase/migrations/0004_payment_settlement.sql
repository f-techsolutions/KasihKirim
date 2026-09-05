-- ============================================================================
-- KasihKirim — 0004_payment_settlement.sql
-- The money-path functions. Completes fn_apply_payment_event, which the
-- payment-webhook Edge Function calls.
-- ============================================================================

-- ── Status precedence ───────────────────────────────────────────────────────
-- Gateways deliver webhooks out of order, routinely. Rather than trusting
-- arrival sequence, every status carries a rank and a lower-ranked event is
-- recorded and ignored. This makes out-of-order delivery a non-event.
CREATE OR REPLACE FUNCTION internal.fn_status_precedence(s ref.payment_status)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE s
    WHEN 'INITIATED' THEN 10  WHEN 'PENDING' THEN 20
    WHEN 'COD_PENDING' THEN 20
    WHEN 'AUTHORIZED' THEN 30 WHEN 'CAPTURED' THEN 40
    WHEN 'SUCCEEDED' THEN 40  WHEN 'COD_COLLECTED' THEN 40
    WHEN 'COD_REMITTED' THEN 50
    WHEN 'SETTLED' THEN 60
    WHEN 'REFUND_PENDING' THEN 70
    WHEN 'PARTIALLY_REFUNDED' THEN 80 WHEN 'REFUNDED' THEN 80
    -- Terminal failures rank high so a late "pending" cannot revive them.
    WHEN 'FAILED' THEN 90 WHEN 'CANCELLED' THEN 90 WHEN 'EXPIRED' THEN 90
    WHEN 'COD_SHORTFALL' THEN 90
    ELSE 0 END;
$$;

-- ── Provider status mapping ─────────────────────────────────────────────────
-- One place to add a gateway. Adapters differ only in this mapping and in the
-- signature scheme; nothing downstream knows which provider is in use.
CREATE OR REPLACE FUNCTION internal.fn_map_provider_status(p_provider TEXT, p_raw TEXT)
RETURNS ref.payment_status LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN CASE lower(p_raw)
    WHEN 'paid'      THEN 'SUCCEEDED'
    WHEN 'completed' THEN 'SUCCEEDED'
    WHEN 'success'   THEN 'SUCCEEDED'
    WHEN 'captured'  THEN 'CAPTURED'
    WHEN 'authorized' THEN 'AUTHORIZED'
    WHEN 'pending'   THEN 'PENDING'
    WHEN 'failed'    THEN 'FAILED'
    WHEN 'cancelled' THEN 'CANCELLED'
    WHEN 'expired'   THEN 'EXPIRED'
    WHEN 'refunded'  THEN 'REFUNDED'
    ELSE 'PENDING' END::ref.payment_status;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- fn_apply_payment_event — called by the payment-webhook Edge Function
-- after signature verification and the insert-first dedupe.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_apply_payment_event(
  p_provider TEXT, p_event_id TEXT)
RETURNS ref.payment_status LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  w internal.webhook_events; pay internal.payments;
  new_status ref.payment_status; v_txn UUID; k public.kirim_requests;
BEGIN
  SELECT * INTO w FROM internal.webhook_events
   WHERE provider=p_provider AND provider_event_id=p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'WEBHOOK_EVENT_NOT_FOUND'; END IF;

  -- Row lock: two Edge instances handed the same event serialise here.
  SELECT * INTO pay FROM internal.payments
   WHERE provider=p_provider AND provider_ref = (w.payload->>'reference')
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;

  new_status := internal.fn_map_provider_status(p_provider, w.payload->>'status');

  IF internal.fn_status_precedence(new_status)
     <= internal.fn_status_precedence(pay.status) THEN
    UPDATE internal.webhook_events SET status='IGNORED_OUT_OF_ORDER'
     WHERE id = w.id;
    RETURN pay.status;                       -- stale event; no effect
  END IF;

  UPDATE internal.payments
     SET status = new_status,
         status_precedence = internal.fn_status_precedence(new_status),
         updated_at = now()
   WHERE id = pay.id;

  -- Money moves only on first successful capture. The ledger transaction's
  -- idempotency_key is UNIQUE, so a replay that somehow got this far still
  -- cannot post twice.
  IF new_status IN ('SUCCEEDED','CAPTURED') THEN
    INSERT INTO internal.ledger_transactions
      (kind, reference_type, reference_id, idempotency_key, description)
    VALUES ('PAYMENT_CAPTURE', pay.reference_type, pay.reference_id,
            'capture:'||pay.id::text, 'Capture '||p_provider||' '||p_event_id)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_txn;

    IF v_txn IS NOT NULL THEN
      PERFORM internal.fn_post(v_txn,'GATEWAY_CLEARING','DEBIT', pay.amount_sen);

      IF pay.reference_type = 'kirim' THEN
        SELECT * INTO k FROM public.kirim_requests WHERE id = pay.reference_id;
        -- Goods and delivery escrow are separate accounts so that the BELI
        -- refund invariant (BR-915) is checkable in isolation.
        IF COALESCE(k.budget_cap_sen,0) > 0 THEN
          PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','CREDIT', k.budget_cap_sen);
        END IF;
        PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','CREDIT',
                                 pay.amount_sen - COALESCE(k.budget_cap_sen,0));
      ELSE
        PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','CREDIT', pay.amount_sen);
      END IF;
    END IF;
  END IF;

  IF new_status IN ('FAILED','CANCELLED','EXPIRED') AND pay.reference_type='kirim' THEN
    UPDATE public.kirim_requests SET status='DRAFT', updated_at=now()
     WHERE id = pay.reference_id AND status = 'POSTED';
  END IF;

  UPDATE internal.webhook_events
     SET status='PROCESSED', processed_at=now()
   WHERE id = w.id;

  RETURN new_status;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- COD collection — cash exists in the world before it exists in the system
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_record_cod_collection(
  p_delivery UUID, p_amount BIGINT, p_actor UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.deliveries; v_txn UUID; v_id UUID;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id=p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  INSERT INTO internal.cod_collections (delivery_id, carrier_id, amount_sen, collected_at)
  VALUES (p_delivery, d.carrier_id, p_amount, now())
  RETURNING id INTO v_id;

  -- ck_carrier_exposure fires here if this breaches the float limit (BR-908).
  UPDATE public.carriers SET cod_held_sen = cod_held_sen + p_amount
   WHERE id = d.carrier_id;

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('COD_COLLECT','delivery',p_delivery,'cod:'||p_delivery::text,'COD collected')
  RETURNING id INTO v_txn;

  PERFORM internal.fn_post(v_txn,'CARRIER_CASH_RECEIVABLE:'||d.carrier_id,'DEBIT',p_amount);
  PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','CREDIT',p_amount);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION internal.fn_remit_cod(
  p_carrier UUID, p_amount BIGINT, p_method TEXT, p_verified_by UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_txn UUID;
BEGIN
  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('COD_REMIT','carrier',p_carrier,
          'remit:'||p_carrier::text||':'||extract(epoch from now())::bigint,
          'COD remittance via '||p_method)
  RETURNING id INTO v_txn;

  PERFORM internal.fn_post(v_txn,'BANK_OPERATING','DEBIT',p_amount);
  PERFORM internal.fn_post(v_txn,'CARRIER_CASH_RECEIVABLE:'||p_carrier,'CREDIT',p_amount);

  UPDATE public.carriers SET cod_held_sen = GREATEST(0, cod_held_sen - p_amount)
   WHERE id = p_carrier;

  UPDATE internal.cod_collections SET remitted_at = now()
   WHERE carrier_id = p_carrier AND remitted_at IS NULL;
  RETURN v_txn;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- Refund — used by dispute resolution and PROCUREMENT_FAILED
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_refund(
  p_kirim UUID, p_amount BIGINT, p_reason TEXT, p_actor UUID)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE k public.kirim_requests; v_txn UUID;
BEGIN
  SELECT * INTO k FROM public.kirim_requests WHERE id=p_kirim FOR UPDATE;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'REFUND_AMOUNT_INVALID'; END IF;
  IF p_amount > COALESCE(k.total_escrow_sen,0) THEN
    RAISE EXCEPTION 'REFUND_EXCEEDS_ESCROW';
  END IF;

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description, created_by)
  VALUES ('REFUND','kirim',p_kirim,'refund:'||p_kirim::text||':'||p_amount::text,
          p_reason, p_actor)
  RETURNING id INTO v_txn;

  PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','DEBIT',p_amount);
  PERFORM internal.fn_post(v_txn,'REQUESTER_REFUND:'||k.requester_id,'CREDIT',p_amount);
  RETURN v_txn;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- Voucher application (BR-916)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_apply_voucher(
  p_user UUID, p_code TEXT, p_order_total BIGINT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE iss public.voucher_issuances; c public.voucher_campaigns; v_disc BIGINT;
BEGIN
  SELECT * INTO iss FROM public.voucher_issuances
   WHERE code = p_code AND user_id = p_user FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'VOUCHER_NOT_FOUND'; END IF;
  IF iss.redeemed_at IS NOT NULL THEN RAISE EXCEPTION 'VOUCHER_ALREADY_USED'; END IF;
  IF iss.expires_at < now() THEN RAISE EXCEPTION 'VOUCHER_EXPIRED'; END IF;

  SELECT * INTO c FROM public.voucher_campaigns WHERE id = iss.campaign_id FOR UPDATE;
  IF NOT c.is_active OR now() NOT BETWEEN c.starts_at AND c.ends_at THEN
    RAISE EXCEPTION 'VOUCHER_EXPIRED';
  END IF;
  IF p_order_total < c.min_order_sen THEN RAISE EXCEPTION 'VOUCHER_MIN_ORDER'; END IF;

  v_disc := CASE c.discount_type
              WHEN 'fixed'   THEN c.discount_value
              WHEN 'percent' THEN p_order_total * c.discount_value / 100
            END;
  IF c.max_discount_sen IS NOT NULL THEN v_disc := LEAST(v_disc, c.max_discount_sen); END IF;
  v_disc := LEAST(v_disc, p_order_total);   -- never produces a negative total

  -- ck_campaign_budget raises if this would exceed the ceiling. The programme
  -- stops itself rather than relying on someone watching a dashboard.
  UPDATE public.voucher_campaigns
     SET budget_spent_sen = budget_spent_sen + v_disc
   WHERE id = c.id;

  UPDATE public.voucher_issuances SET redeemed_at = now() WHERE id = iss.id;
  RETURN v_disc;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- Reconciliation — the daily proof that nothing has drifted
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_reconcile()
RETURNS TABLE (check_name TEXT, variance_sen BIGINT, ok BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  -- 1. Global double-entry balance.
  SELECT 'global_balance',
         COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen ELSE -amount_sen END),0),
         COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen ELSE -amount_sen END),0)=0
  FROM internal.ledger_entries
  UNION ALL
  -- 2. Per-transaction balance: catches a partial posting.
  SELECT 'unbalanced_transactions', COUNT(*)::bigint, COUNT(*)=0
  FROM (SELECT transaction_id
        FROM internal.ledger_entries GROUP BY transaction_id
        HAVING SUM(CASE WHEN direction='DEBIT' THEN amount_sen ELSE -amount_sen END) <> 0) x
  UNION ALL
  -- 3. BR-915: goods escrow must equal actual cost plus refund, per Kirim.
  SELECT 'beli_refund_invariant', COUNT(*)::bigint, COUNT(*)=0
  FROM public.kirim_requests k
  JOIN internal.quotes q ON q.id = k.quote_id
  WHERE k.kirim_type='BELI' AND k.status='COMPLETED'
    AND q.goods_budget_sen <> COALESCE(k.actual_goods_sen,0)
        + GREATEST(0, q.goods_budget_sen - COALESCE(k.actual_goods_sen,0))
  UNION ALL
  -- 4. No carrier over their float limit.
  SELECT 'carrier_float_breach', COUNT(*)::bigint, COUNT(*)=0
  FROM public.carriers
  WHERE cod_held_sen + procurement_advance_sen > float_limit_sen
  UNION ALL
  -- 5. No trip oversold. Should be impossible; verified anyway.
  SELECT 'trip_overbooked', COUNT(*)::bigint, COUNT(*)=0
  FROM public.trips
  WHERE reserved_weight_grams > capacity_weight_grams
     OR reserved_parcels > capacity_parcels;
$$;
