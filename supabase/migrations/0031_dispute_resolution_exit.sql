-- ============================================================================
-- KasihKirim — 0031_dispute_resolution_exit.sql
--
-- DISPUTED is a one-way door, and P1 made it load-bearing.
--
-- ref.delivery_transition_rules has carried DELIVERED --OPEN_DISPUTE-->
-- DISPUTED since the first seed, and carries NOTHING out of DISPUTED. That
-- was harmless while nothing could raise a dispute. 0028 gave customers a
-- way in, so it is no longer harmless:
--
--   * the auto-release sweep selects on status = 'DELIVERED', so a DISPUTED
--     delivery is never examined again;
--   * CONFIRM_RECEIPT has no rule from DISPUTED, so the customer cannot
--     release it either;
--   * rpc_admin_resolve_dispute clears holds_escrow, which unblocks
--     fn_settlement_blocked_reason -- and changes nothing, because no path
--     reaches settlement any more.
--
-- So an admin could rule entirely in the seller's favour and the seller would
-- still never be paid. The money sits in escrow forever, on a delivery that
-- physically completed. Found in the P1 final audit.
--
-- Fixed by completing the state machine, not by special-casing settlement:
-- resolving a dispute returns the delivery to DELIVERED, where the ordinary
-- eligibility rules and the ordinary sweep pick it up again.
--
-- Known limitation, deliberately not invented around: a delivery whose
-- dispute ended in a refund also returns to DELIVERED, where
-- fn_settlement_blocked_reason reports PAYMENT_NOT_HELD and the sweep skips
-- it on every pass. That is honest -- the goods were delivered and the money
-- was returned -- but it leaves a row the sweep keeps looking at. A terminal
-- status for refunded-after-delivery needs a new ref.kirim_status value, and
-- adding delivery statuses is outside what P1 was approved to do.
-- ============================================================================

-- ── An admin transition has never been able to write its own event row ──────
-- public.delivery_events carries
--     CHECK (source <> 'admin' OR admin_reason IS NOT NULL)
-- and internal.fn_delivery_transition sets source = 'admin' whenever the
-- acting role matches admin\_%, while never supplying admin_reason. So every
-- admin-role transition raises a constraint violation at the audit insert --
-- including the AUTO_SETTLE rule and both admin CANCEL rules, none of which
-- any test had exercised. Pre-existing; surfaced by the dispute exit below,
-- which is admin-only.
--
-- The reason is taken from p_meta and REQUIRED rather than defaulted. The
-- constraint exists so an admin override carries a written justification;
-- filling it in with the event name would satisfy the check and defeat it.
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

INSERT INTO ref.delivery_transition_rules
  (from_status, event, to_status, allowed_roles, applies_to_types, requires_proof, proof_leg)
VALUES
  -- Back to the settlement queue. Admin-only: the parties argued, an admin
  -- decided, and only an admin closes it.
  ('DISPUTED','RESOLVE_DISPUTE','DELIVERED',
   '{admin_ops,admin_support,admin_super}','{BELI,HANTAR,PASARAN}',false,NULL),
  -- The order should never have shipped. Releases the reservation and voids
  -- the allocations through the branches 0027 already installed.
  ('DISPUTED','CANCEL','CANCELLED',
   '{admin_ops,admin_super}','{BELI,HANTAR,PASARAN}',false,NULL)
ON CONFLICT (from_status, event) DO NOTHING;

-- ── Resolution drives the delivery, not just the dispute row ────────────────
-- Reproduced from 0029 with the state-machine step added. Everything else --
-- the admin check, the status whitelist, the refund reversal -- is unchanged.
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
  v_delivery_status TEXT;
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

  IF v_final AND p_refund_sen > 0 AND v_dispute.order_id IS NOT NULL THEN
    v_txn := internal.fn_refund_order(
      v_dispute.order_id, p_refund_sen,
      'Dispute '||v_dispute.id::text||': '||COALESCE(p_note,''), (SELECT auth.uid()));
  END IF;

  -- Clearing holds_escrow is not enough on its own: while the delivery sits
  -- at DISPUTED, the sweep (which selects on DELIVERED) never looks at it
  -- again and CONFIRM_RECEIPT has no rule from there. Returning it to
  -- DELIVERED puts it back under the ordinary eligibility rules, which is
  -- what decides whether it settles or stays put.
  IF v_final AND v_dispute.delivery_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.disputes
                      WHERE delivery_id = v_dispute.delivery_id AND resolved_at IS NULL)
  THEN
    IF (SELECT status FROM public.deliveries WHERE id = v_dispute.delivery_id) = 'DISPUTED' THEN
      PERFORM internal.fn_delivery_transition(
        v_dispute.delivery_id, 'RESOLVE_DISPUTE', (SELECT auth.uid()),
        'admin_ops'::ref.user_role, 'dispute-resolved:'||v_dispute.id::text,
        jsonb_build_object('dispute_id', v_dispute.id, 'outcome', p_status,
                           'admin_reason', COALESCE(NULLIF(trim(COALESCE(p_note,'')),''),
                                                    'Dispute '||p_status)));
    END IF;
  END IF;

  SELECT status::text INTO v_delivery_status
    FROM public.deliveries WHERE id = v_dispute.delivery_id;

  RETURN jsonb_build_object(
    'dispute_id', v_dispute.id,
    'status',     v_dispute.status,
    'refund_sen', v_dispute.refund_sen,
    'refund_txn', v_txn,
    'delivery_status', v_delivery_status,
    'resolved',   v_final);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_resolve_dispute(UUID,TEXT,TEXT,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_admin_resolve_dispute(UUID,TEXT,TEXT,BIGINT) TO authenticated;
