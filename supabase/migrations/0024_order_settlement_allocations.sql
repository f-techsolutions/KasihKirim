-- ============================================================================
-- KasihKirim — 0024_order_settlement_allocations.sql
--
-- P0 FINANCIAL CORRECTNESS FIX.
--
-- THE DEFECT (internal.fn_settle_delivery, defined once in 0003, never
-- redefined since -- confirmed against pg_get_functiondef on a fresh
-- database):
--
--   d := deliveries WHERE id = p_delivery
--   k := kirim_requests WHERE id = d.kirim_id
--   q := quotes WHERE id = k.quote_id
--   v_actual := COALESCE(k.actual_goods_sen, 0)
--   v_refund := q.goods_budget_sen - v_actual
--   ...
--   IF v_refund > 0 THEN fn_post(REQUESTER_REFUND:<requester>, CREDIT, v_refund)
--
-- kirim_requests.actual_goods_sen is the Kirim BELI field meaning "what the
-- carrier actually spent buying the goods". A marketplace order never sets
-- it: the buyer already paid the seller's listed price, nobody goes shopping.
-- So for an order-linked delivery v_actual is 0, and the whole goods value
-- lands in v_refund and is credited to REQUESTER_REFUND -- the buyer keeps
-- the product AND is refunded what it cost. The seller is credited nothing,
-- because no SELLER_PAYABLE leg exists anywhere in the function.
--
-- The same function has a second, quieter failure on today's data: because
-- fn_quote_kirim zeroes goods for any type other than BELI, q.goods_budget_sen
-- is 0 for a PASARAN quote, the `IF q.goods_budget_sen > 0` goods leg is
-- skipped entirely, and the goods money simply never leaves escrow. Either
-- way the seller is never paid. Which of the two fires depends only on
-- whether goods value was put in the quote.
--
-- THE FIX: settlement branches explicitly on the transaction type
-- (kirim_requests.kirim_type = 'PASARAN', whose ck_pasaran_has_order
-- constraint already guarantees order_id IS NOT NULL) and settles a
-- marketplace order from declared allocations, never from Kirim's
-- budget-minus-actual refund arithmetic. Kirim BELI/HANTAR keep byte-for-byte
-- the behaviour they have today.
--
-- No competing system is introduced. This reuses internal.payments,
-- internal.ledger_*, internal.fn_post, the existing escrow account codes,
-- the existing 'settle:<delivery>' idempotency key, and the existing dispute
-- hold. ledger_accounts.owner_type and payouts.payee_type already permit
-- 'seller'; this is the first code to use that.
--
-- NOT activated by this migration: nothing here creates a payment, and
-- ref.feature_gates.prepaid_payments_enabled remains false. This is the
-- correctness floor that marketplace payment will later stand on.
-- ============================================================================

-- ── 1. Declared settlement intent ────────────────────────────────────────────
-- The ledger stays authoritative for balances. This table records what a
-- payment was *for*, so an audit can answer "who was owed what, and when was
-- it released" without replaying entries, and so settlement has one row per
-- party to check against rather than recomputing commercial terms at
-- release time.
CREATE TABLE IF NOT EXISTS internal.payment_allocations (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  payment_id        UUID NOT NULL REFERENCES internal.payments(id) ON DELETE RESTRICT,
  order_id          UUID NOT NULL REFERENCES public.orders(id)     ON DELETE RESTRICT,
  allocation_type   TEXT NOT NULL CHECK (allocation_type IN ('SELLER','CARRIER','PLATFORM','AGENT')),
  -- Who is owed. NULL only for PLATFORM, which is KasihKirim itself.
  payee_type        TEXT CHECK (payee_type IN ('seller','carrier','agent')),
  payee_id          UUID,
  amount_sen        BIGINT NOT NULL CHECK (amount_sen >= 0),
  currency          TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
  status            TEXT NOT NULL DEFAULT 'HELD'
                      CHECK (status IN ('HELD','SETTLED','REFUNDED','CANCELLED')),
  settlement_txn_id UUID REFERENCES internal.ledger_transactions(id),
  settled_at        TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- One allocation per party per payment: makes a duplicated allocation a
  -- constraint violation rather than a silent double credit.
  CONSTRAINT ux_allocation_once UNIQUE (payment_id, allocation_type),
  -- PLATFORM is the house; everyone else must be identified.
  CONSTRAINT ck_allocation_payee CHECK (
    (allocation_type = 'PLATFORM' AND payee_type IS NULL AND payee_id IS NULL)
    OR (allocation_type <> 'PLATFORM' AND payee_type IS NOT NULL AND payee_id IS NOT NULL)),
  CONSTRAINT ck_allocation_settled CHECK (
    (status = 'SETTLED') = (settled_at IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS ix_payment_allocations_order   ON internal.payment_allocations(order_id);
CREATE INDEX IF NOT EXISTS ix_payment_allocations_payment ON internal.payment_allocations(payment_id);
CREATE INDEX IF NOT EXISTS ix_payment_allocations_payee   ON internal.payment_allocations(payee_type, payee_id)
  WHERE payee_id IS NOT NULL;

-- Schema internal is already REVOKEd from anon/authenticated (0000) and is not
-- in config.toml's exposed schema list, so this table is unreachable from
-- PostgREST. The explicit REVOKE restates that for this table specifically.
REVOKE ALL ON internal.payment_allocations FROM anon, authenticated;
ALTER TABLE internal.payment_allocations ENABLE ROW LEVEL SECURITY;

-- ── 2. Allocation builder ────────────────────────────────────────────────────
-- Derives every amount from authoritative server-side sources: the order row
-- written by rpc_checkout (goods subtotal, seller commission) and the delivery
-- quote written by fn_quote_kirim (delivery fee, platform's delivery cut).
-- Nothing here is client-supplied.
--
-- Split, matching the approved model:
--   SELLER   = order.goods_subtotal_sen - order.commission_sen
--   CARRIER  = quote.delivery_fee_sen - quote.commission_sen - delivery.agent_fee_sen
--   AGENT    = delivery.agent_fee_sen
--   PLATFORM = order.commission_sen + quote.commission_sen
CREATE OR REPLACE FUNCTION internal.fn_allocate_order_payment(
  p_payment_id UUID, p_delivery_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  pay internal.payments; o public.orders; d public.deliveries;
  k public.kirim_requests; q internal.quotes;
  v_seller BIGINT; v_carrier BIGINT; v_platform BIGINT; v_agent BIGINT; v_sum BIGINT;
BEGIN
  SELECT * INTO pay FROM internal.payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;
  IF pay.reference_type <> 'order' THEN RAISE EXCEPTION 'PAYMENT_NOT_FOR_ORDER'; END IF;

  SELECT * INTO o FROM public.orders WHERE id = pay.reference_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;
  -- Inconsistent order/payment/delivery relationship: the delivery being
  -- settled must belong to the very order this payment is for.
  IF k.order_id IS DISTINCT FROM o.id THEN
    RAISE EXCEPTION 'ALLOCATION_ORDER_MISMATCH';
  END IF;
  IF o.seller_id IS NULL THEN RAISE EXCEPTION 'ALLOCATION_SELLER_MISSING'; END IF;

  SELECT * INTO q FROM internal.quotes WHERE id = k.quote_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;

  -- Who funds a discount (platform, seller, or campaign) is a commercial
  -- decision that has not been made. Rather than silently charging it to
  -- whichever party the arithmetic happens to land on, refuse.
  IF COALESCE(o.discount_sen,0) <> 0 THEN
    RAISE EXCEPTION 'ALLOCATION_DISCOUNT_UNSUPPORTED';
  END IF;

  v_agent    := COALESCE(d.agent_fee_sen, 0);
  v_seller   := o.goods_subtotal_sen - COALESCE(o.commission_sen,0);
  v_carrier  := q.delivery_fee_sen - COALESCE(q.commission_sen,0) - v_agent;
  v_platform := COALESCE(o.commission_sen,0) + COALESCE(q.commission_sen,0);

  IF v_seller < 0 OR v_carrier < 0 OR v_platform < 0 OR v_agent < 0 THEN
    RAISE EXCEPTION 'ALLOCATION_NEGATIVE';
  END IF;

  v_sum := v_seller + v_carrier + v_platform + v_agent;
  IF v_sum <> pay.amount_sen THEN
    RAISE EXCEPTION 'ALLOCATION_SUM_MISMATCH: parts % <> payment %', v_sum, pay.amount_sen;
  END IF;

  -- ux_allocation_once makes a second call a no-op rather than a double
  -- credit, so this is safe to retry.
  INSERT INTO internal.payment_allocations
    (payment_id, order_id, allocation_type, payee_type, payee_id, amount_sen)
  VALUES
    (pay.id, o.id, 'SELLER',   'seller',  o.seller_id,   v_seller),
    (pay.id, o.id, 'CARRIER',  'carrier', d.carrier_id,  v_carrier),
    (pay.id, o.id, 'PLATFORM',  NULL,      NULL,         v_platform)
  ON CONFLICT ON CONSTRAINT ux_allocation_once DO NOTHING;

  IF v_agent > 0 THEN
    INSERT INTO internal.payment_allocations
      (payment_id, order_id, allocation_type, payee_type, payee_id, amount_sen)
    VALUES (pay.id, o.id, 'AGENT', 'agent', d.carrier_id, v_agent)
    ON CONFLICT ON CONSTRAINT ux_allocation_once DO NOTHING;
  END IF;
END;
$function$;

-- ── 3. Explicit settlement eligibility ───────────────────────────────────────
-- Returns NULL when the delivery may settle, otherwise the reason it may not.
-- Split out from fn_settle_delivery so it is independently testable and so
-- an auto-release sweep can ask the same question without attempting a write.
CREATE OR REPLACE FUNCTION internal.fn_settlement_blocked_reason(p_delivery UUID)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  d public.deliveries; k public.kirim_requests; pay internal.payments;
  v_alloc_total BIGINT; v_alloc_count INT;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RETURN 'DELIVERY_NOT_FOUND'; END IF;

  -- Already settled: the ledger's own unique key is the source of truth.
  IF EXISTS (SELECT 1 FROM internal.ledger_transactions
              WHERE idempotency_key = 'settle:'||p_delivery::text) THEN
    RETURN 'ALREADY_SETTLED';
  END IF;

  IF EXISTS (SELECT 1 FROM public.disputes
              WHERE delivery_id = p_delivery AND holds_escrow AND resolved_at IS NULL) THEN
    RETURN 'ESCROW_HELD_BY_DISPUTE';
  END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  -- The remaining conditions are marketplace-only, deliberately.
  --
  -- For Kirim, proof of delivery is already enforced where it belongs: on the
  -- OUT_FOR_DELIVERY -> DELIVERED transition, whose rule carries
  -- requires_proof and which 0014 made actually enforce. Re-checking it here
  -- would not add safety, but it would change the behaviour of Kirim
  -- settlement, which this migration guarantees it does not touch --
  -- 04_money.test.sql settles a BELI delivery directly to assert the BR-915
  -- refund arithmetic, and is right to.
  --
  -- A marketplace order needs the check at settlement as well, because
  -- settlement is the moment the seller's money stops being refundable.
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

    -- Only money actually captured may be released.
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

-- ── 4. Settlement, branching explicitly on transaction type ──────────────────
CREATE OR REPLACE FUNCTION internal.fn_settle_delivery(p_delivery UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  d public.deliveries; k public.kirim_requests; q internal.quotes;
  pay internal.payments; a internal.payment_allocations;
  v_txn UUID; v_actual BIGINT; v_refund BIGINT; v_blocked TEXT;
  v_goods_held BIGINT; v_delivery_held BIGINT;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id=p_delivery FOR UPDATE;
  SELECT * INTO k FROM public.kirim_requests WHERE id=d.kirim_id;
  SELECT * INTO q FROM internal.quotes WHERE id=k.quote_id;

  v_blocked := internal.fn_settlement_blocked_reason(p_delivery);
  -- Settling twice is a no-op, not an error: fn_delivery_transition may be
  -- retried, and the caller has already got what it asked for.
  IF v_blocked = 'ALREADY_SETTLED' THEN RETURN; END IF;
  IF v_blocked IS NOT NULL THEN RAISE EXCEPTION '%', v_blocked; END IF;

  INSERT INTO internal.ledger_transactions (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('SETTLEMENT','delivery',p_delivery,'settle:'||p_delivery::text,'Settlement '||k.reference_code)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_txn;
  IF v_txn IS NULL THEN RETURN; END IF;   -- lost a concurrent race; already settled

  IF k.kirim_type = 'PASARAN' THEN
    -- ── Marketplace order ──────────────────────────────────────────────────
    -- The customer bought a product at the seller's price. There is no
    -- budget to reconcile and nothing to refund: every sen is already owed
    -- to a named party by the declared allocations.
    SELECT * INTO pay FROM internal.payments
     WHERE reference_type='order' AND reference_id=k.order_id
     ORDER BY created_at DESC LIMIT 1;

    SELECT COALESCE(SUM(amount_sen),0) INTO v_goods_held
      FROM internal.payment_allocations
     WHERE payment_id = pay.id AND allocation_type = 'SELLER';
    v_delivery_held := pay.amount_sen - v_goods_held;

    -- Release the holds funded at capture, then credit each party.
    PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','DEBIT',    v_goods_held);
    PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','DEBIT', v_delivery_held);

    FOR a IN SELECT * FROM internal.payment_allocations
              WHERE payment_id = pay.id ORDER BY allocation_type
    LOOP
      PERFORM internal.fn_post(v_txn,
        CASE a.allocation_type
          WHEN 'SELLER'   THEN 'SELLER_PAYABLE:'||a.payee_id::text
          WHEN 'CARRIER'  THEN 'CARRIER_PAYABLE:'||a.payee_id::text
          WHEN 'AGENT'    THEN 'AGENT_PAYABLE'
          ELSE 'PLATFORM_COMMISSION'
        END, 'CREDIT', a.amount_sen);
    END LOOP;

    UPDATE internal.payment_allocations
       SET status='SETTLED', settled_at=now(), settlement_txn_id=v_txn, updated_at=now()
     WHERE payment_id = pay.id;

    UPDATE internal.payments
       SET status='SETTLED', status_precedence=internal.fn_status_precedence('SETTLED'),
           updated_at=now()
     WHERE id = pay.id;

    UPDATE public.orders SET status='SETTLED', updated_at=now() WHERE id = k.order_id;

  ELSE
    -- ── Kirim (BELI / HANTAR) — unchanged from 0003 ────────────────────────
    v_actual := COALESCE(k.actual_goods_sen, 0);
    v_refund := q.goods_budget_sen - v_actual;
    IF v_refund < 0 THEN RAISE EXCEPTION 'BR-915 VIOLATION: refund would be negative'; END IF;

    -- Goods leg: reimburse at cost, refund the remainder. No commission on goods.
    IF q.goods_budget_sen > 0 THEN
      PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','DEBIT',  q.goods_budget_sen);
      IF v_actual > 0 THEN
        PERFORM internal.fn_post(v_txn,'CARRIER_PAYABLE:'||d.carrier_id,'CREDIT', v_actual);
      END IF;
      IF v_refund > 0 THEN
        PERFORM internal.fn_post(v_txn,'REQUESTER_REFUND:'||k.requester_id,'CREDIT', v_refund);
      END IF;
    END IF;

    -- Service leg: commission out, remainder to the carrier.
    PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','DEBIT', q.delivery_fee_sen);
    PERFORM internal.fn_post(v_txn,'PLATFORM_COMMISSION','CREDIT', q.commission_sen);
    IF d.agent_fee_sen > 0 THEN
      PERFORM internal.fn_post(v_txn,'AGENT_PAYABLE','CREDIT', d.agent_fee_sen);
    END IF;
    PERFORM internal.fn_post(v_txn,'CARRIER_PAYABLE:'||d.carrier_id,'CREDIT',
                             q.delivery_fee_sen - q.commission_sen - d.agent_fee_sen);

    UPDATE public.carriers
       SET procurement_advance_sen = GREATEST(0, procurement_advance_sen - v_actual)
     WHERE id = d.carrier_id;
  END IF;

  UPDATE public.deliveries SET status='COMPLETED', completed_at=now() WHERE id=p_delivery;
  UPDATE public.kirim_requests SET status='COMPLETED' WHERE id=k.id;
  UPDATE public.carriers SET completed_count = completed_count + 1 WHERE id = d.carrier_id;
END;
$function$;

-- ── 5. Capture must fund the two escrow accounts the split releases ──────────
-- fn_apply_payment_event (0004) credited the entire amount of an order
-- payment to ESCROW_HELD_DELIVERY, because only Kirim had a goods concept.
-- Settlement now debits ESCROW_HELD_GOODS for the seller's share, so capture
-- has to have funded it -- otherwise the two legs describe different money
-- and the escrow accounts drift. Kirim capture is untouched.
CREATE OR REPLACE FUNCTION internal.fn_split_order_capture(
  p_txn UUID, p_payment_id UUID, p_amount_sen BIGINT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_goods BIGINT;
BEGIN
  SELECT COALESCE(SUM(amount_sen),0) INTO v_goods
    FROM internal.payment_allocations
   WHERE payment_id = p_payment_id AND allocation_type = 'SELLER';

  PERFORM internal.fn_post(p_txn,'ESCROW_HELD_GOODS','CREDIT', v_goods);
  PERFORM internal.fn_post(p_txn,'ESCROW_HELD_DELIVERY','CREDIT', p_amount_sen - v_goods);
END;
$function$;

-- ── 7. Narrow the function grants ────────────────────────────────────────────
-- Postgres grants EXECUTE to PUBLIC on every new function. Schema internal
-- already has no USAGE for anon/authenticated, so these were unreachable
-- anyway, but the project's rule (0012's header) is to revoke first rather
-- than rely on a single layer. Every caller of these is another SECURITY
-- DEFINER function owned by postgres, so nothing legitimate loses access.
REVOKE ALL ON FUNCTION internal.fn_allocate_order_payment(UUID,UUID)   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_settlement_blocked_reason(UUID)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_split_order_capture(UUID,UUID,BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_settle_delivery(UUID)               FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE internal.payment_allocations IS
  'Declared settlement intent per payment. The ledger remains authoritative '
  'for balances; this records who was owed what, and when it was released.';

-- ── 6. Order-aware capture ───────────────────────────────────────────────────
-- Reproduced verbatim from the live definition (pg_get_functiondef) with one
-- branch added, so no unrelated behaviour drifts. Kirim and topup capture are
-- byte-for-byte unchanged.

CREATE OR REPLACE FUNCTION internal.fn_apply_payment_event(p_provider text, p_event_id text)
 RETURNS ref.payment_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      ELSIF pay.reference_type = 'order' THEN
        -- 0024: a marketplace order's goods share belongs in the goods
        -- escrow, so settlement's SELLER leg has a funded account to debit.
        PERFORM internal.fn_split_order_capture(v_txn, pay.id, pay.amount_sen);
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
END $function$;
