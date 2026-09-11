-- ============================================================================
-- KasihKirim — 0029_settlement_sweep_and_earnings.sql   (P1-G, P1-I, P1-K)
--
-- Four things, all of which the P1 audit found either missing or newly broken.
--
--  1. THE AUTO-RELEASE SWEEP IS CURRENTLY UNSAFE. seed.sql schedules
--
--       cron.schedule('settle_delivered','*/10 * * * *',
--         $j$SELECT internal.fn_settle_delivery(id) FROM public.deliveries
--            WHERE status='DELIVERED' AND settlement_due_at < now()$j$);
--
--     Before 0024, fn_settle_delivery either worked or raised on data that
--     could not occur. 0024 gave it real eligibility rules, and an ineligible
--     marketplace delivery now RAISES -- PROOF_MISSING, PAYMENT_NOT_HELD,
--     ALLOCATION_MISSING. A raise inside a set-returning SELECT aborts the
--     whole statement, so ONE ineligible order would stop every other
--     delivery in that sweep from settling, silently, every ten minutes.
--     Replaced with a function that asks fn_settlement_blocked_reason first,
--     skips what it must, and contains a failure to the row that caused it.
--
--  2. RISK HOLDS WERE NEVER ENFORCED. internal.risk_signals has existed since
--     0001 and rpc_risk_signal writes to it, but nothing has ever read it.
--     A signal can now declare itself settlement-blocking.
--
--  3. EARNINGS WERE NOT LEDGER-DERIVED. rpc_my_earnings summed
--     deliveries.carrier_earning_sen -- a column written at carrier
--     assignment from the quote, which is an estimate of what a carrier will
--     be owed, not a record of what they have been credited. That is a second
--     source of truth for money. It now reads the ledger, which is the only
--     one, and it answers for sellers too.
--
--  4. REFUNDS HAD NO MARKETPLACE PATH. internal.fn_refund (0004) is
--     Kirim-only: it reads kirim_requests.total_escrow_sen and credits
--     REQUESTER_REFUND, and never sets reverses_id. An order's money sits in
--     a four-way allocation it cannot see. fn_refund_order reverses the
--     capture entry-for-entry and links the two transactions, so the ledger
--     shows a reversal rather than a second, unexplained movement.
-- ============================================================================

-- ── 1. A risk signal can hold settlement ────────────────────────────────────
ALTER TABLE internal.risk_signals
  ADD COLUMN IF NOT EXISTS holds_settlement BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS resolved_at      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS resolved_by      UUID;

CREATE INDEX IF NOT EXISTS ix_risk_signals_hold
  ON internal.risk_signals (subject_type, subject_id)
  WHERE holds_settlement AND resolved_at IS NULL;

-- The existing three-argument rpc_risk_signal keeps its exact signature and
-- behaviour; holding settlement is opt-in and defaults to false, so no signal
-- written by anything already deployed starts blocking money.
CREATE OR REPLACE FUNCTION internal.fn_raise_risk_hold(
  p_subject_type TEXT, p_subject_id UUID, p_signal TEXT,
  p_severity INT DEFAULT 4, p_details JSONB DEFAULT '{}')
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO internal.risk_signals
    (subject_type, subject_id, signal, severity, details, holds_settlement)
  VALUES (p_subject_type, p_subject_id, p_signal, p_severity, p_details, true)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- ── 2. Eligibility, now including risk holds ────────────────────────────────
-- Reproduced from 0024 with one added check. Everything else -- including the
-- deliberate scoping of the proof/payment/allocation checks to PASARAN, which
-- keeps Kirim settlement byte-identical -- is unchanged.
CREATE OR REPLACE FUNCTION internal.fn_settlement_blocked_reason(p_delivery UUID)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  d public.deliveries; k public.kirim_requests; pay internal.payments;
  v_alloc_total BIGINT; v_alloc_count INT;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RETURN 'DELIVERY_NOT_FOUND'; END IF;

  IF EXISTS (SELECT 1 FROM internal.ledger_transactions
              WHERE idempotency_key = 'settle:'||p_delivery::text) THEN
    RETURN 'ALREADY_SETTLED';
  END IF;

  IF EXISTS (SELECT 1 FROM public.disputes
              WHERE delivery_id = p_delivery AND holds_escrow AND resolved_at IS NULL) THEN
    RETURN 'ESCROW_HELD_BY_DISPUTE';
  END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  -- A live risk hold on the delivery, its kirim or its order freezes the
  -- money for the same reason a dispute does: somebody has said stop.
  IF EXISTS (
    SELECT 1 FROM internal.risk_signals r
     WHERE r.holds_settlement AND r.resolved_at IS NULL
       AND ((r.subject_type = 'delivery' AND r.subject_id = p_delivery)
         OR (r.subject_type = 'kirim'    AND r.subject_id = d.kirim_id)
         OR (r.subject_type = 'order'    AND r.subject_id = k.order_id))
  ) THEN
    RETURN 'RISK_HOLD';
  END IF;

  IF k.kirim_type = 'PASARAN' THEN
    IF EXISTS (
      SELECT 1 FROM ref.delivery_transition_rules r
       WHERE r.to_status = 'DELIVERED' AND r.requires_proof
         AND r.proof_leg IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.proofs pr
                          WHERE pr.delivery_id = p_delivery AND pr.leg = r.proof_leg)
    ) THEN
      RETURN 'PROOF_MISSING';
    END IF;

    SELECT * INTO pay FROM internal.payments
     WHERE reference_type = 'order' AND reference_id = k.order_id
     ORDER BY created_at DESC LIMIT 1;
    IF NOT FOUND THEN RETURN 'PAYMENT_MISSING'; END IF;

    IF pay.status NOT IN ('CAPTURED','SUCCEEDED') THEN RETURN 'PAYMENT_NOT_HELD'; END IF;

    SELECT count(*), COALESCE(SUM(amount_sen),0)
      INTO v_alloc_count, v_alloc_total
      FROM internal.payment_allocations WHERE payment_id = pay.id;
    IF v_alloc_count = 0 THEN RETURN 'ALLOCATION_MISSING'; END IF;
    IF v_alloc_total <> pay.amount_sen THEN RETURN 'ALLOCATION_SUM_MISMATCH'; END IF;
    IF EXISTS (SELECT 1 FROM internal.payment_allocations
                WHERE payment_id = pay.id AND status <> 'HELD') THEN
      RETURN 'ALLOCATION_NOT_HELD';
    END IF;
  END IF;

  RETURN NULL;
END;
$function$;

-- ── 3. The auto-release sweep ───────────────────────────────────────────────
/** Settles every delivery whose 48-hour window has expired and that is
 *  actually eligible. Safe to run repeatedly and safe to run concurrently:
 *
 *   * eligibility is asked before anything is attempted, so an ineligible row
 *     is skipped rather than raising;
 *   * each settlement is wrapped in its own exception block, so one bad row
 *     cannot abort the batch -- the failure that made 0024 dangerous under
 *     the old cron statement;
 *   * fn_settle_delivery is itself idempotent (the 'settle:<delivery>' ledger
 *     key is UNIQUE and a duplicate returns without posting), so a second
 *     sweep over the same row is a no-op, not a double credit.
 *
 *  settlement_due_at is set by fn_delivery_transition on entry to DELIVERED,
 *  from ref.app_config.settlement_window_hours (48). Nothing here reads a
 *  clock supplied by a client. */
CREATE OR REPLACE FUNCTION internal.fn_sweep_settlements(p_limit INT DEFAULT 500)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  r RECORD; v_reason TEXT;
  v_examined INT := 0; v_settled INT := 0; v_blocked INT := 0; v_failed INT := 0;
  v_reasons JSONB := '{}'::jsonb; v_result JSONB; v_run UUID;
BEGIN
  INSERT INTO internal.job_runs (job_name) VALUES ('settle_delivered')
  RETURNING id INTO v_run;

  FOR r IN
    SELECT id FROM public.deliveries
     WHERE status = 'DELIVERED'
       AND settlement_due_at IS NOT NULL
       AND settlement_due_at < now()
     ORDER BY settlement_due_at
     LIMIT GREATEST(1, p_limit)
  LOOP
    v_examined := v_examined + 1;
    v_reason := internal.fn_settlement_blocked_reason(r.id);

    IF v_reason IS NOT NULL THEN
      v_blocked := v_blocked + 1;
      v_reasons := jsonb_set(v_reasons, ARRAY[v_reason],
                     to_jsonb(COALESCE((v_reasons->>v_reason)::int, 0) + 1), true);
      CONTINUE;
    END IF;

    BEGIN
      PERFORM internal.fn_settle_delivery(r.id);
      v_settled := v_settled + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Contained: the subtransaction rolls back, the sweep carries on, and
      -- the reason is recorded rather than lost to a cron log nobody reads.
      v_failed := v_failed + 1;
      v_reasons := jsonb_set(v_reasons, ARRAY['ERROR:'||SQLERRM],
                     to_jsonb(COALESCE((v_reasons->>('ERROR:'||SQLERRM))::int, 0) + 1), true);
    END;
  END LOOP;

  v_result := jsonb_build_object(
    'examined', v_examined, 'settled', v_settled,
    'blocked', v_blocked, 'failed', v_failed, 'reasons', v_reasons);

  UPDATE internal.job_runs
     SET ended_at = now(),
         outcome  = CASE WHEN v_failed > 0 THEN 'PARTIAL' ELSE 'OK' END,
         detail   = v_result
   WHERE id = v_run;

  RETURN v_result;
END $$;

-- Re-point the scheduled job at the safe sweep. Wrapped exactly as seed.sql
-- wraps its own scheduling, because pg_cron is absent in CI and in the local
-- harness; scheduling remains whatever the target environment already had --
-- this migration activates nothing new.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('settle_delivered');
    PERFORM cron.schedule('settle_delivered','*/10 * * * *',
      $j$SELECT internal.fn_sweep_settlements()$j$);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron unavailable (%). settle_delivered left as-is.', SQLERRM;
END $cron$;

-- ── 4. Ledger-derived earnings ──────────────────────────────────────────────
/** What the ledger says each party is owed.
 *
 *  available_sen is a real balance: credits minus debits on that party's
 *  payable account, which only settlement writes. pending_sen is what has
 *  been declared but not yet released -- HELD allocations for the
 *  marketplace, and for Kirim the quoted carrier share of deliveries still in
 *  flight, which has no ledger entry until settlement by design.
 *
 *  Payouts are deliberately not netted off here. A payout is a separate
 *  operation against internal.payouts and posts its own ledger transaction;
 *  it never rewrites a historical entry, so the balance below stays a
 *  derivation and never becomes a second stored wallet. */
CREATE OR REPLACE FUNCTION internal.fn_account_balance_sen(p_code TEXT)
RETURNS BIGINT LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT COALESCE(SUM(CASE WHEN e.direction='CREDIT' THEN e.amount_sen
                           ELSE -e.amount_sen END), 0)::bigint
    FROM internal.ledger_entries e
    JOIN internal.ledger_accounts a ON a.id = e.account_id
   WHERE a.account_code = p_code;
$$;

CREATE OR REPLACE FUNCTION public.rpc_my_earnings()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_carrier UUID := authz.my_carrier_id();
  v_seller UUID;
  v_avail BIGINT := 0; v_pending BIGINT := 0;
  v_s_avail BIGINT := 0; v_s_pending BIGINT := 0;
  v_out JSONB;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT id INTO v_seller FROM public.sellers WHERE user_id = v_uid;

  IF v_carrier IS NOT NULL THEN
    v_avail := internal.fn_account_balance_sen('CARRIER_PAYABLE:'||v_carrier::text);

    -- Declared but unreleased. Marketplace work is in the allocations;
    -- Kirim work has no ledger row until settlement, so it is read from the
    -- quote-derived column on the delivery -- an estimate, and labelled one.
    SELECT COALESCE(SUM(a.amount_sen),0) INTO v_pending
      FROM internal.payment_allocations a
     WHERE a.status='HELD' AND a.payee_type='carrier' AND a.payee_id = v_carrier;

    v_pending := v_pending + COALESCE((
      SELECT SUM(d.carrier_earning_sen) FROM public.deliveries d
       JOIN public.kirim_requests k ON k.id = d.kirim_id
       WHERE d.carrier_id = v_carrier
         AND k.kirim_type <> 'PASARAN'
         AND d.status IN ('PICKED_UP','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED')), 0);
  END IF;

  IF v_seller IS NOT NULL THEN
    v_s_avail := internal.fn_account_balance_sen('SELLER_PAYABLE:'||v_seller::text);
    SELECT COALESCE(SUM(a.amount_sen),0) INTO v_s_pending
      FROM internal.payment_allocations a
     WHERE a.status='HELD' AND a.payee_type='seller' AND a.payee_id = v_seller;
  END IF;

  v_out := jsonb_build_object(
    'available_sen', v_avail,
    'pending_sen',   v_pending,
    'seller_available_sen', v_s_avail,
    'seller_pending_sen',   v_s_pending,
    'source', 'ledger');

  IF v_carrier IS NOT NULL THEN
    v_out := v_out || jsonb_build_object(
      'cod_held_sen',   (SELECT cod_held_sen   FROM public.carriers WHERE id=v_carrier),
      'float_limit_sen',(SELECT float_limit_sen FROM public.carriers WHERE id=v_carrier));
  END IF;

  RETURN v_out;
END $$;

-- ── 5. Marketplace refund as a ledger reversal ──────────────────────────────
/** Reverses an order's capture, entry for entry, and links the reversal to
 *  the transaction it undoes through ledger_transactions.reverses_id.
 *
 *  A reversal is the only refund shape this implements. A partial refund is
 *  not a reversal -- it is a renegotiation of a four-way split, and which
 *  party gives up which sen is a commercial decision nobody has made. It is
 *  refused rather than guessed at, the same stance 0024 takes on discounts.
 *
 *  Refuses outright once the money has been released: after settlement the
 *  seller and carrier have been credited, and clawing that back is a payout
 *  adjustment, not a payment reversal. */
CREATE OR REPLACE FUNCTION internal.fn_refund_order(
  p_order      UUID,
  p_amount_sen BIGINT,
  p_reason     TEXT,
  p_actor      UUID DEFAULT NULL)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o public.orders; pay internal.payments; cap internal.ledger_transactions;
  v_txn UUID; e RECORD;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  SELECT * INTO pay FROM internal.payments
   WHERE reference_type='order' AND reference_id = p_order
   ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_MISSING'; END IF;

  IF pay.status = 'SETTLED' THEN RAISE EXCEPTION 'REFUND_AFTER_SETTLEMENT'; END IF;
  IF p_amount_sen <> pay.amount_sen THEN RAISE EXCEPTION 'PARTIAL_REFUND_UNSUPPORTED'; END IF;

  SELECT * INTO cap FROM internal.ledger_transactions
   WHERE idempotency_key = 'capture:'||pay.id::text;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOTHING_CAPTURED'; END IF;

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description,
     created_by, reverses_id)
  VALUES ('REFUND','order', p_order, 'refund:'||pay.id::text,
          COALESCE(p_reason,'Refund '||o.reference_code), p_actor, cap.id)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_txn;
  IF v_txn IS NULL THEN
    -- Already refunded. Return the existing transaction rather than posting
    -- the reversal a second time.
    SELECT id INTO v_txn FROM internal.ledger_transactions
     WHERE idempotency_key = 'refund:'||pay.id::text;
    RETURN v_txn;
  END IF;

  -- Mirror every entry of the capture with the opposite direction. This is
  -- what makes it a reversal rather than a new, differently-shaped movement:
  -- the two transactions sum to nothing, on every account they touched.
  FOR e IN SELECT a.account_code, en.direction, en.amount_sen
             FROM internal.ledger_entries en
             JOIN internal.ledger_accounts a ON a.id = en.account_id
            WHERE en.transaction_id = cap.id
  LOOP
    PERFORM internal.fn_post(v_txn, e.account_code,
      CASE WHEN e.direction='DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END::ref.ledger_direction,
      e.amount_sen);
  END LOOP;

  UPDATE internal.payment_allocations
     SET status='REFUNDED', updated_at=now()
   WHERE payment_id = pay.id AND status='HELD';

  UPDATE internal.payments
     SET status='REFUNDED', status_precedence=internal.fn_status_precedence('REFUNDED'),
         updated_at=now()
   WHERE id = pay.id;

  UPDATE public.orders SET status='REFUNDED', updated_at=now() WHERE id = p_order;

  RETURN v_txn;
END $$;

-- ── 6. Dispute resolution actually pays the refund it records ───────────────
-- Reproduced from 0023 with the financial step added. 0023 wrote refund_sen
-- onto the dispute row and posted nothing, so a "RESOLVED_REFUND_FULL"
-- dispute refunded no money to anybody.
CREATE OR REPLACE FUNCTION public.rpc_admin_resolve_dispute(
  p_dispute_id UUID, p_status TEXT,
  p_note TEXT DEFAULT NULL, p_refund_sen BIGINT DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_dispute public.disputes;
  v_status  ref.dispute_status;
  v_final   BOOLEAN;
  v_txn     UUID;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_status NOT IN ('UNDER_REVIEW','AWAITING_EVIDENCE','DECIDED',
                      'RESOLVED_REFUND_FULL','RESOLVED_REFUND_PARTIAL',
                      'RESOLVED_REJECTED','RESOLVED_SPLIT','CLOSED') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;
  IF p_refund_sen < 0 THEN RAISE EXCEPTION 'INVALID_REFUND'; END IF;

  v_status := p_status::ref.dispute_status;
  v_final  := p_status LIKE 'RESOLVED\_%' OR p_status = 'CLOSED';

  UPDATE public.disputes SET
    status          = v_status,
    resolution_note = COALESCE(p_note, resolution_note),
    refund_sen      = CASE WHEN v_final THEN p_refund_sen ELSE refund_sen END,
    holds_escrow    = CASE WHEN v_final THEN false ELSE holds_escrow END,
    resolved_by     = CASE WHEN v_final THEN (SELECT auth.uid()) ELSE resolved_by END,
    resolved_at     = CASE WHEN v_final THEN now() ELSE resolved_at END
  WHERE id = p_dispute_id
  RETURNING * INTO v_dispute;

  IF v_dispute.id IS NULL THEN RAISE EXCEPTION 'DISPUTE_NOT_FOUND'; END IF;

  -- The money. Clearing holds_escrow is what UNBLOCKS settlement; if the
  -- decision was to refund instead, the reversal must actually happen, and it
  -- leaves the payment REFUNDED so fn_settlement_blocked_reason will not then
  -- release the same money to the seller and carrier.
  IF v_final AND p_refund_sen > 0 AND v_dispute.order_id IS NOT NULL THEN
    v_txn := internal.fn_refund_order(
      v_dispute.order_id, p_refund_sen,
      'Dispute '||v_dispute.id::text||': '||COALESCE(p_note,''), (SELECT auth.uid()));
  END IF;

  RETURN jsonb_build_object(
    'dispute_id', v_dispute.id,
    'status',     v_dispute.status,
    'refund_sen', v_dispute.refund_sen,
    'refund_txn', v_txn,
    'resolved',   v_final);
END;
$function$;

-- ── 7. Grants ───────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.fn_raise_risk_hold(TEXT,UUID,TEXT,INT,JSONB)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_settlement_blocked_reason(UUID)            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_sweep_settlements(INT)                     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_account_balance_sen(TEXT)                  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_refund_order(UUID,BIGINT,TEXT,UUID)        FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_my_earnings() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_earnings() TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_resolve_dispute(UUID,TEXT,TEXT,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_admin_resolve_dispute(UUID,TEXT,TEXT,BIGINT) TO authenticated;

COMMENT ON FUNCTION internal.fn_sweep_settlements(INT) IS
  'Auto-release sweep. Checks eligibility before acting and contains a '
  'per-row failure, so one ineligible order cannot stall the batch.';
COMMENT ON FUNCTION internal.fn_refund_order(UUID,BIGINT,TEXT,UUID) IS
  'Full refund as a ledger reversal linked through reverses_id. Partial '
  'refunds are refused: the split renegotiation has no approved policy.';
