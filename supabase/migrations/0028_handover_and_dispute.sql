-- ============================================================================
-- KasihKirim — 0028_handover_and_dispute.sql   (P1-E, P1-H)
--
-- Two tables that have existed since 0001 and have never had any code behind
-- them:
--
--   * public.handover_codes -- schema, a partial unique index for the single
--     active code per leg, an attempt counter and a lockout column, and a
--     REVOKE making it readable by nobody (0003, restated in 0010). Nothing
--     has ever issued or verified a code.
--
--   * public.disputes -- schema, a SELECT policy scoped to the two parties
--     and admins, and a SELECT grant. There is no INSERT policy and no RPC,
--     so a customer has had no way to raise one. ref.delivery_transition_rules
--     has carried DELIVERED --OPEN_DISPUTE--> DISPUTED all along, but firing
--     it moved the delivery without creating a dispute row, so
--     fn_settlement_blocked_reason -- which blocks on the ROW, not the status
--     -- would still have released the money.
--
-- Neither of these moves money. A handover code proves custody changed hands;
-- a dispute freezes settlement. Refund stays a separate, admin-controlled
-- financial operation (rpc_admin_resolve_dispute), exactly as before.
-- ============================================================================

INSERT INTO ref.app_config (key, value, description) VALUES
  ('dispute_sla_hours',   '72', 'Target for a first admin decision on a new dispute'),
  ('handover_code_ttl_hours', '24', 'How long an issued handover code stays usable')
ON CONFLICT (key) DO NOTHING;

-- ── 1. Handover codes ───────────────────────────────────────────────────────
-- The plaintext code is returned exactly once, to the party handing over, and
-- never stored: public.handover_codes keeps only a SHA-256 of
-- delivery:leg:code, so the digest is useless on another delivery even if the
-- table were somehow read. It is not readable in any case -- the table has no
-- SELECT policy and no grant.
--
-- sha256() and gen_random_uuid() are pg_catalog builtins, so this works under
-- SET search_path='' without depending on where pgcrypto happens to be
-- installed (public locally, extensions on Supabase).

CREATE OR REPLACE FUNCTION internal.fn_handover_digest(
  p_delivery UUID, p_leg ref.handover_leg, p_code TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE SET search_path='' AS $$
  SELECT encode(sha256((p_delivery::text||':'||p_leg::text||':'||p_code)::bytea), 'hex');
$$;

/** Issues a fresh six-digit code for one leg of a delivery, locking out any
 *  code previously issued for that leg. Returns the plaintext, once. */
CREATE OR REPLACE FUNCTION internal.fn_issue_handover_code(
  p_delivery UUID, p_leg ref.handover_leg)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_code TEXT; v_expires TIMESTAMPTZ; v_prev UUID;
BEGIN
  -- Digits drawn from gen_random_uuid(), which is CSPRNG-backed, rather than
  -- random(), which is not.
  v_code := lpad(((('x'||substr(replace(gen_random_uuid()::text,'-',''),1,8))::bit(32)::bigint
                   & 2147483647) % 1000000)::text, 6, '0');

  v_expires := now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                          WHERE key='handover_code_ttl_hours')||' hours')::interval;

  -- ux_handover_active permits one live code per (delivery, leg): retire the
  -- old one rather than leaving two valid codes in circulation.
  UPDATE public.handover_codes SET locked_at = now()
   WHERE delivery_id = p_delivery AND leg = p_leg
     AND consumed_at IS NULL AND locked_at IS NULL
  RETURNING id INTO v_prev;

  INSERT INTO public.handover_codes
    (delivery_id, leg, code_hash, qr_nonce, rotated_from, expires_at)
  VALUES (p_delivery, p_leg,
          internal.fn_handover_digest(p_delivery, p_leg, v_code),
          gen_random_uuid()::text, v_prev, v_expires);

  RETURN jsonb_build_object('code', v_code, 'leg', p_leg, 'expires_at', v_expires);
END $$;

/** The party handing goods over asks for the code and reads it to the
 *  carrier. Pickup belongs to whoever is releasing the goods -- the seller on
 *  a marketplace order, the requester on a Kirim. Dropoff belongs to the
 *  recipient. */
CREATE OR REPLACE FUNCTION public.rpc_issue_handover_code(
  p_delivery UUID, p_leg TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid(); v_leg ref.handover_leg;
  d public.deliveries; k public.kirim_requests; v_ok BOOLEAN := false;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_leg NOT IN ('pickup','dropoff') THEN RAISE EXCEPTION 'INVALID_LEG'; END IF;
  v_leg := p_leg::ref.handover_leg;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  IF v_leg = 'dropoff' THEN
    v_ok := (k.requester_id = v_uid);
  ELSIF k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL THEN
    v_ok := EXISTS (SELECT 1 FROM public.orders o
                    JOIN public.sellers s ON s.id = o.seller_id
                    WHERE o.id = k.order_id AND s.user_id = v_uid);
  ELSE
    v_ok := (k.requester_id = v_uid);
  END IF;

  IF NOT v_ok THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  RETURN internal.fn_issue_handover_code(p_delivery, v_leg);
END $$;

/** The carrier types in the code they were given. Returns a result rather
 *  than raising on a wrong code, so the attempt counter survives: a RAISE
 *  would roll the increment back and make the lockout unreachable. */
CREATE OR REPLACE FUNCTION public.rpc_verify_handover_code(
  p_delivery UUID, p_leg TEXT, p_code TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid(); v_leg ref.handover_leg;
  d public.deliveries; hc public.handover_codes;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_leg NOT IN ('pickup','dropoff') THEN RAISE EXCEPTION 'INVALID_LEG'; END IF;
  v_leg := p_leg::ref.handover_leg;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  -- Only the carrier actually carrying this delivery may present a code.
  IF d.carrier_id IS DISTINCT FROM authz.my_carrier_id() THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  SELECT * INTO hc FROM public.handover_codes
   WHERE delivery_id = p_delivery AND leg = v_leg
     AND consumed_at IS NULL AND locked_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('verified', false, 'reason', 'NO_ACTIVE_CODE');
  END IF;

  IF hc.expires_at < now() THEN
    UPDATE public.handover_codes SET locked_at = now() WHERE id = hc.id;
    RETURN jsonb_build_object('verified', false, 'reason', 'EXPIRED');
  END IF;

  IF hc.code_hash = internal.fn_handover_digest(p_delivery, v_leg, COALESCE(p_code,'')) THEN
    UPDATE public.handover_codes
       SET consumed_at = now(), attempts = attempts + 1
     WHERE id = hc.id;
    INSERT INTO internal.handover_nonces (nonce, delivery_id, leg, consumed_by)
    VALUES (hc.qr_nonce, p_delivery, v_leg, v_uid)
    ON CONFLICT (nonce) DO NOTHING;
    RETURN jsonb_build_object('verified', true, 'leg', v_leg);
  END IF;

  UPDATE public.handover_codes
     SET attempts = attempts + 1,
         locked_at = CASE WHEN attempts + 1 >= max_attempts THEN now() ELSE locked_at END
   WHERE id = hc.id
  RETURNING * INTO hc;

  RETURN jsonb_build_object(
    'verified', false,
    'reason', CASE WHEN hc.locked_at IS NOT NULL THEN 'LOCKED' ELSE 'INVALID' END,
    'attempts_left', GREATEST(0, hc.max_attempts - hc.attempts));
END $$;

-- ── 2. Customer-raised disputes ─────────────────────────────────────────────
/** Lets the customer on a delivery raise a dispute against it.
 *
 *  What this does NOT do is as important as what it does: it moves no money,
 *  accepts no amount from the caller, and does not refund. refund_sen stays 0
 *  until an admin decides one through rpc_admin_resolve_dispute. All it does
 *  is create the row that internal.fn_settlement_blocked_reason already looks
 *  for, which freezes settlement while the claim is open. */
CREATE OR REPLACE FUNCTION public.rpc_open_dispute(
  p_delivery    UUID,
  p_category    TEXT,
  p_description TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  d public.deliveries; k public.kirim_requests;
  v_against UUID; v_dispute UUID; v_sla INT;
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

  IF EXISTS (SELECT 1 FROM public.disputes
              WHERE delivery_id = p_delivery AND resolved_at IS NULL) THEN
    RAISE EXCEPTION 'DISPUTE_ALREADY_OPEN';
  END IF;

  -- Who it is against: the seller's user on a marketplace order, the carrier
  -- otherwise. Recorded for routing, never used to move money.
  IF k.kirim_type = 'PASARAN' AND k.order_id IS NOT NULL THEN
    SELECT s.user_id INTO v_against
      FROM public.orders o JOIN public.sellers s ON s.id = o.seller_id
     WHERE o.id = k.order_id;
  ELSE
    SELECT c.user_id INTO v_against FROM public.carriers c WHERE c.id = d.carrier_id;
  END IF;

  SELECT (value#>>'{}')::int INTO v_sla FROM ref.app_config WHERE key='dispute_sla_hours';

  INSERT INTO public.disputes
    (delivery_id, order_id, raised_by, against_id, category, status,
     description, holds_escrow, refund_sen, sla_due_at)
  VALUES (p_delivery, k.order_id, v_uid, v_against, p_category, 'OPEN',
          trim(p_description), true, 0,
          now() + (COALESCE(v_sla,72)||' hours')::interval)
  RETURNING id INTO v_dispute;

  -- Move the delivery only if it is still sitting at DELIVERED; a second
  -- party may already have taken it to DISPUTED.
  IF d.status = 'DELIVERED' THEN
    PERFORM internal.fn_delivery_transition(
      p_delivery, 'OPEN_DISPUTE', v_uid, 'customer'::ref.user_role,
      'dispute:'||v_dispute::text,
      jsonb_build_object('dispute_id', v_dispute, 'category', p_category));
  END IF;

  INSERT INTO audit.audit_logs (actor_id, actor_role, action, entity_type, entity_id, after)
  VALUES (v_uid, 'customer', 'DISPUTE_OPENED', 'dispute', v_dispute,
          jsonb_build_object('delivery_id', p_delivery, 'category', p_category));

  RETURN jsonb_build_object(
    'dispute_id', v_dispute, 'status', 'OPEN',
    'delivery_status', (SELECT status FROM public.deliveries WHERE id = p_delivery),
    'settlement_blocked', internal.fn_settlement_blocked_reason(p_delivery));
END $$;

-- ── 3. Grants ───────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.fn_handover_digest(UUID,ref.handover_leg,TEXT)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_issue_handover_code(UUID,ref.handover_leg)   FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_issue_handover_code(UUID,TEXT)       FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_verify_handover_code(UUID,TEXT,TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_open_dispute(UUID,TEXT,TEXT)         FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_issue_handover_code(UUID,TEXT)       TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_verify_handover_code(UUID,TEXT,TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_open_dispute(UUID,TEXT,TEXT)         TO authenticated;

COMMENT ON FUNCTION public.rpc_open_dispute(UUID,TEXT,TEXT) IS
  'Customer-raised dispute. Freezes settlement by creating the row '
  'fn_settlement_blocked_reason checks. Moves no money and takes no amount.';
