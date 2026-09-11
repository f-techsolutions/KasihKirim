-- ============================================================================
-- KasihKirim — 0032_dispute_audit_trail.sql
--
-- FINAL MERGE-READINESS HARDENING: dispute audit trail gap.
--
-- ref.delivery_transition_rules permits {customer,seller,carrier} to fire
-- DELIVERED --OPEN_DISPUTE--> DISPUTED (seeded since day one; 0030 fixed the
-- bug that wrongly refused a seller their own order). rpc_open_dispute
-- (0028) is the only thing that has ever written a public.disputes row, and
-- it is deliberately customer-only. A seller or carrier reaching
-- OPEN_DISPUTE through the generic public.rpc_delivery_transition therefore
-- moves the delivery to DISPUTED with no disputes row at all: no category,
-- no description, no audit_logs entry, invisible to the admin dispute queue.
--
-- This is not a financial hole -- fn_settlement_blocked_reason blocks on the
-- disputes ROW (holds_escrow), not on delivery.status, so a bare transition
-- with no row freezes nothing by itself, and 22_marketplace_authz_hardening's
-- TEST 5e/7c already document that the buyer can still file afterwards. It is
-- an operational one: nothing routes a seller/carrier-raised dispute to an
-- admin, and if the buyer never separately files, the delivery sits at
-- DISPUTED with no record an admin's dispute queue would ever surface.
--
-- FIX: pull dispute-record creation out of rpc_open_dispute into a shared,
-- idempotent internal function, and call it from inside
-- internal.fn_delivery_transition itself whenever a transition actually
-- lands on DISPUTED -- regardless of which entry point or role reached it.
-- That makes "dispute state" and "audit record" the same event structurally,
-- rather than a policy two different callers have to remember to uphold.
--
-- The state machine itself is UNCHANGED: customer, seller and carrier keep
-- exactly the transitions 0030 gave them. This only guarantees that landing
-- on DISPUTED always leaves a disputes row behind it -- with a category and
-- description when the caller supplies one (customer, via rpc_open_dispute),
-- and a truthful default when it does not (the raw transition path, which
-- carries no free-text fields).
--
-- No financial mutation is added anywhere in this migration. holds_escrow
-- defaults to true exactly as rpc_open_dispute already set it, so a
-- seller/carrier-raised dispute now blocks settlement exactly as a
-- customer-raised one always has -- closing a second, smaller gap this audit
-- found: previously only the buyer's path froze the money at all.
-- ============================================================================

/** Creates (or returns the existing) disputes row for a delivery. Idempotent:
 *  a delivery can hold at most one unresolved dispute, so a second caller in
 *  the same window is handed the row that already exists rather than
 *  minting a duplicate. Never raises on a missing or invalid category or a
 *  short description -- callers that must enforce those (rpc_open_dispute)
 *  validate before calling this; a caller that cannot supply them (a bare
 *  role transition) still gets a truthful, auditable row instead of none. */
CREATE OR REPLACE FUNCTION internal.fn_create_dispute_record(
  p_delivery      UUID,
  p_raised_by     UUID,
  p_raised_role   ref.user_role,
  p_category      TEXT DEFAULT NULL,
  p_description   TEXT DEFAULT NULL)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  d public.deliveries; k public.kirim_requests;
  v_against UUID; v_category TEXT; v_description TEXT;
  v_sla INT; v_dispute UUID;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  -- One live dispute per delivery. Whoever asked second is handed the row
  -- that already exists, matching what rpc_open_dispute has always done
  -- when the buyer files after a bare transition already opened one. Their
  -- own filing still leaves a trace -- a second raiser gets their own audit
  -- entry against the same dispute, even though no second row is created.
  SELECT id INTO v_dispute FROM public.disputes
   WHERE delivery_id = p_delivery AND resolved_at IS NULL;
  IF v_dispute IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.disputes
                    WHERE id = v_dispute AND raised_by = p_raised_by) THEN
      INSERT INTO audit.audit_logs (actor_id, actor_role, action, entity_type, entity_id, after)
      VALUES (p_raised_by, p_raised_role, 'DISPUTE_ALSO_RAISED', 'dispute', v_dispute,
              jsonb_build_object('delivery_id', p_delivery, 'raised_role', p_raised_role));
    END IF;
    RETURN v_dispute;
  END IF;

  -- public.disputes.category carries its own CHECK; coerce rather than trust
  -- a caller (the bare transition path) that has no free-text field to fill
  -- it from.
  v_category := CASE WHEN p_category IN
      ('non_delivery','damaged','wrong_item','not_as_described',
       'payment','overcharge','conduct','other')
    THEN p_category ELSE 'other' END;

  v_description := NULLIF(trim(COALESCE(p_description,'')), '');
  IF v_description IS NULL OR length(v_description) < 10 THEN
    v_description := 'Dispute opened via ' || p_raised_role::text ||
                      ' delivery transition (delivery ' || p_delivery::text || ')';
  END IF;

  -- Against whom: the counterparty to whoever is raising it, not a fixed
  -- side. A customer disputes the seller (PASARAN) or carrier (Kirim) --
  -- unchanged from rpc_open_dispute. A seller has no counterparty dispute
  -- against themselves, so they dispute the assigned carrier; a carrier
  -- disputes the requester. Recorded for routing and RLS visibility only --
  -- against_id is nullable and never used to move money.
  v_against := CASE p_raised_role
    WHEN 'seller'  THEN (SELECT c.user_id FROM public.carriers c WHERE c.id = d.carrier_id)
    WHEN 'carrier' THEN k.requester_id
    ELSE CASE WHEN k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL
           THEN (SELECT s.user_id FROM public.orders o
                  JOIN public.sellers s ON s.id = o.seller_id
                 WHERE o.id = k.order_id)
           ELSE (SELECT c.user_id FROM public.carriers c WHERE c.id = d.carrier_id)
         END
  END;

  SELECT (value#>>'{}')::int INTO v_sla FROM ref.app_config WHERE key = 'dispute_sla_hours';

  INSERT INTO public.disputes
    (delivery_id, order_id, raised_by, against_id, category, status,
     description, holds_escrow, refund_sen, sla_due_at)
  VALUES (p_delivery, k.order_id, p_raised_by, v_against, v_category, 'OPEN',
          v_description, true, 0, now() + (COALESCE(v_sla,72)||' hours')::interval)
  RETURNING id INTO v_dispute;

  INSERT INTO audit.audit_logs (actor_id, actor_role, action, entity_type, entity_id, after)
  VALUES (p_raised_by, p_raised_role, 'DISPUTE_OPENED', 'dispute', v_dispute,
          jsonb_build_object('delivery_id', p_delivery, 'category', v_category,
                             'raised_role', p_raised_role));

  RETURN v_dispute;
END $$;

REVOKE ALL ON FUNCTION internal.fn_create_dispute_record(UUID,UUID,ref.user_role,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;

-- ── Every landing on DISPUTED leaves a row behind it ────────────────────────
-- Reproduced from 0031 with one addition: right after a transition actually
-- lands on DISPUTED, record it. p_meta carries category/description when the
-- caller has them (rpc_open_dispute passes its own validated input through);
-- a bare role transition supplies neither and gets the coerced default above.
-- Applies to every kirim_type, matching applies_to_types on the OPEN_DISPUTE
-- rule -- Kirim disputes get the same audit trail marketplace ones do.
CREATE OR REPLACE FUNCTION internal.fn_delivery_transition(
  p_delivery UUID, p_event TEXT, p_actor UUID, p_role ref.user_role,
  p_idem TEXT DEFAULT NULL, p_meta JSONB DEFAULT '{}')
RETURNS ref.kirim_status LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  d public.deliveries; k public.kirim_requests; rule ref.delivery_transition_rules;
  v_source TEXT; v_admin_reason TEXT;
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

  v_source := CASE WHEN p_role::text LIKE 'admin\_%' THEN 'admin' ELSE 'app' END;
  IF v_source = 'admin' THEN
    v_admin_reason := NULLIF(trim(COALESCE(p_meta->>'admin_reason', p_meta->>'reason','')), '');
    IF v_admin_reason IS NULL THEN RAISE EXCEPTION 'ADMIN_REASON_REQUIRED'; END IF;
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
    -- Returning from DISPUTED must not restart the 48-hour clock: the
    -- customer already had their window before they raised the claim.
    settlement_due_at = CASE WHEN rule.to_status='DELIVERED' AND settlement_due_at IS NULL
      THEN now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                     WHERE key='settlement_window_hours')||' hours')::interval
      ELSE settlement_due_at END,
    updated_at = now()
  WHERE id = p_delivery;

  UPDATE public.kirim_requests SET status=rule.to_status, updated_at=now() WHERE id=k.id;

  INSERT INTO public.delivery_events
    (delivery_id, from_status, to_status, event, actor_id, actor_role, source,
     idempotency_key, metadata, admin_reason)
  VALUES (p_delivery, d.status, rule.to_status, p_event, p_actor, p_role,
          v_source, p_idem, p_meta, v_admin_reason);

  -- Landing on DISPUTED always leaves a disputes row, whoever raised it.
  -- Idempotent: if rpc_open_dispute already created one (it calls this
  -- function AFTER its own insert when status was DELIVERED), this finds
  -- that row and returns without a second insert.
  IF rule.to_status = 'DISPUTED' THEN
    PERFORM internal.fn_create_dispute_record(
      p_delivery, p_actor, p_role, p_meta->>'category', p_meta->>'description');
  END IF;

  IF k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL THEN
    IF rule.to_status = 'PICKED_UP' THEN
      PERFORM internal.fn_commit_order_stock(k.order_id);
    END IF;

    IF rule.to_status = 'DELIVERED' AND p_event <> 'RESOLVE_DISPUTE' THEN
      PERFORM internal.fn_capture_order_cod(p_delivery);
      UPDATE public.orders SET status='FULFILLED', updated_at=now()
       WHERE id = k.order_id AND status NOT IN ('SETTLED','REFUNDED','PARTIALLY_REFUNDED');
    END IF;

    IF rule.to_status = 'CANCELLED' THEN
      PERFORM internal.fn_release_order_stock(k.order_id, 'order_released');
      UPDATE internal.payment_allocations a
         SET status='CANCELLED', updated_at=now()
       WHERE a.order_id = k.order_id AND a.status='HELD';
      UPDATE public.orders SET status='CANCELLED', updated_at=now()
       WHERE id = k.order_id AND status NOT IN ('SETTLED','REFUNDED','PARTIALLY_REFUNDED');
    END IF;
  END IF;

  IF p_event = 'CONFIRM_RECEIPT' THEN
    PERFORM internal.fn_settle_delivery(p_delivery);
  END IF;

  RETURN rule.to_status;
END $$;

REVOKE ALL ON FUNCTION internal.fn_delivery_transition(UUID,TEXT,UUID,ref.user_role,TEXT,JSONB)
  FROM PUBLIC, anon, authenticated;

-- ── rpc_open_dispute reuses the shared writer ───────────────────────────────
-- Validation (category enum, description length, ownership, window, the
-- explicit DISPUTE_ALREADY_OPEN raise) is unchanged and still happens here,
-- before the shared function is ever called -- its own leniency exists for
-- the caller that has no free-text fields to validate, not to loosen this
-- one. Everything else about this function -- what it does and does not do
-- -- is unchanged from 0028.
CREATE OR REPLACE FUNCTION public.rpc_open_dispute(
  p_delivery    UUID,
  p_category    TEXT,
  p_description TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  d public.deliveries; k public.kirim_requests;
  v_dispute UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  IF p_category NOT IN ('non_delivery','damaged','wrong_item','not_as_described',
                        'payment','overcharge','conduct','other') THEN
    RAISE EXCEPTION 'INVALID_CATEGORY';
  END IF;
  IF p_description IS NULL OR length(trim(p_description)) < 10 THEN
    RAISE EXCEPTION 'DESCRIPTION_TOO_SHORT';
  END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  -- Ownership: only the customer this delivery belongs to.
  IF k.requester_id IS DISTINCT FROM v_uid THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  -- The escrow window. Before DELIVERED there is nothing to dispute yet;
  -- after settlement the money is gone and the remedy is an admin refund.
  IF d.status NOT IN ('DELIVERED','DISPUTED') THEN
    RAISE EXCEPTION 'DISPUTE_WINDOW_CLOSED';
  END IF;

  -- A genuine re-file by the SAME buyer is refused, exactly as before. A
  -- delivery already at DISPUTED because a seller or carrier's bare
  -- transition put it there (0032) is not that: fn_create_dispute_record
  -- below finds that row and hands it back rather than raising, which is
  -- what lets the buyer still file after the fact -- unchanged from 0028.
  IF EXISTS (SELECT 1 FROM public.disputes
              WHERE delivery_id = p_delivery AND resolved_at IS NULL
                AND raised_by = v_uid) THEN
    RAISE EXCEPTION 'DISPUTE_ALREADY_OPEN';
  END IF;

  v_dispute := internal.fn_create_dispute_record(
    p_delivery, v_uid, 'customer'::ref.user_role, p_category, trim(p_description));

  -- Move the delivery only if it is still sitting at DELIVERED; a second
  -- party may already have taken it to DISPUTED -- fn_create_dispute_record
  -- has already recorded this filing on the row that exists either way.
  IF d.status = 'DELIVERED' THEN
    PERFORM internal.fn_delivery_transition(
      p_delivery, 'OPEN_DISPUTE', v_uid, 'customer'::ref.user_role,
      'dispute:'||v_dispute::text,
      jsonb_build_object('dispute_id', v_dispute, 'category', p_category,
                         'description', p_description));
  END IF;

  RETURN jsonb_build_object(
    'dispute_id', v_dispute, 'status', 'OPEN',
    'delivery_status', (SELECT status FROM public.deliveries WHERE id = p_delivery),
    'settlement_blocked', internal.fn_settlement_blocked_reason(p_delivery));
END $$;

REVOKE ALL ON FUNCTION public.rpc_open_dispute(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_open_dispute(UUID,TEXT,TEXT) TO authenticated;

COMMENT ON FUNCTION internal.fn_create_dispute_record(UUID,UUID,ref.user_role,TEXT,TEXT) IS
  'The only writer of public.disputes. Idempotent per delivery so any entry '
  'point (rpc_open_dispute or a bare role transition to DISPUTED) leaves '
  'exactly one auditable row, never a duplicate or a silent gap.';
