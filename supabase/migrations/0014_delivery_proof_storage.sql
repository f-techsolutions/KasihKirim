-- ============================================================================
-- KasihKirim — 0014_delivery_proof_storage.sql
--
-- Closes the gap docs/CLAUDE_IMPLEMENTATION_PLAN.md §3 named: "No storage
-- buckets provisioned | POD photos, KYC | Phase 6" -- scoped here to the
-- delivery-proof half specifically (pickup/dropoff handover), not the other
-- seven buckets docs/SECURITY.md §5 / docs/ARCHITECTURE.md §12 also design
-- (avatars, product-images, address-photos, receipts, kyc, dispute-evidence,
-- chat-media). Those serve separate features this migration was not asked
-- to touch, and `kyc` specifically needs an Edge Function to satisfy its
-- "every read is audited" requirement (minting a signed URL is a Storage
-- API call, not a plain row SELECT a trigger can hook) -- not invented here.
--
-- Two gaps, found by reading the actual current bodies rather than assuming
-- the schema (0001-0003) already enforced what it declared:
--
--   1. No bucket to upload into. ref.delivery_transition_rules (seeded in
--      seed.sql) already marks CONFIRM_PICKUP/CONFIRM_DELIVERY/CONFIRM_RETURN
--      as requires_proof, and public.proofs (0001) already has the columns
--      to record one -- but no storage.buckets row for 'pod' has ever
--      existed, so there has never been anywhere for a photo to go.
--   2. requires_proof was never enforced. internal.fn_delivery_transition
--      (0003) SELECTs rule.requires_proof and rule.proof_leg into its `rule`
--      variable but never once reads either afterward -- a transition
--      marked requires_proof=true has always been executable with zero
--      proof on record. supabase/tests/03_state_machine.test.sql already
--      asserts the *rule data* says CONFIRM_PICKUP/CONFIRM_DELIVERY require
--      proof; nothing asserted the function actually refused to run without
--      one, because it didn't.
--
-- What this does NOT do: score proof quality against a geofence. SUSPECT
-- currently fires only on the one unambiguous signal already named in
-- docs/SECURITY.md T-12 (a device-reported mock/fake GPS location) --
-- distance_to_node_m is recorded but not scored, because no threshold for
-- "too far to be genuine" is specified anywhere. Guessing one risks flagging
-- real deliveries on a bad GPS fix as fraud. Needs a product decision.
-- Also not done: docs/SECURITY.md's "settlement hold on WEAK/SUSPECT" --
-- internal.fn_settle_delivery does not read proof quality at all today.
-- That is a real, separate gap on the settlement side, not the transition
-- side this migration closes; flagged, not fixed here.
-- ============================================================================

-- ── The bucket ──────────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('pod', 'pod', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Path convention: {delivery_id}/{leg}/{uuid}.{ext} -- matches
-- public.proofs' own (delivery_id, leg) shape (ux_proof_per_leg, 0001).
CREATE POLICY pod_insert_assigned_carrier ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'pod'
    AND EXISTS (
      SELECT 1 FROM public.deliveries d
      JOIN public.carriers c ON c.id = d.carrier_id
      WHERE d.id::text = (storage.foldername(name))[1]
        AND c.user_id = (SELECT auth.uid())
    )
  );

CREATE POLICY pod_select_counterparties ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'pod'
    AND (
      EXISTS (
        SELECT 1 FROM public.deliveries d
        JOIN public.kirim_requests k ON k.id = d.kirim_id
        JOIN public.carriers c ON c.id = d.carrier_id
        WHERE d.id::text = (storage.foldername(name))[1]
          AND (c.user_id = (SELECT auth.uid()) OR k.requester_id = (SELECT auth.uid()))
      )
      OR authz.is_admin()
    )
  );

-- ── Submitting a proof ──────────────────────────────────────────────────────
-- Only the assigned carrier, for now: ref.delivery_transition_rules also
-- allows 'agent' on these events, but this schema has no "assigned agent"
-- relationship on a delivery to check against yet -- narrower than the full
-- rule set on purpose rather than granting write access nothing can scope.
CREATE OR REPLACE FUNCTION public.rpc_submit_proof(
  p_delivery UUID, p_leg TEXT, p_method TEXT, p_captured_at TIMESTAMPTZ,
  p_photo_path TEXT DEFAULT NULL, p_lat DOUBLE PRECISION DEFAULT NULL,
  p_lng DOUBLE PRECISION DEFAULT NULL, p_geo_accuracy_m INT DEFAULT NULL,
  p_is_mock_location BOOLEAN DEFAULT false, p_is_offline_capture BOOLEAN DEFAULT false)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  d public.deliveries; v_uid UUID := (SELECT auth.uid());
  v_leg ref.handover_leg := p_leg::ref.handover_leg;
  v_method ref.proof_method := p_method::ref.proof_method;
  v_quality ref.proof_quality;
  v_proof public.proofs;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.carriers c
                 WHERE c.id = d.carrier_id AND c.user_id = v_uid) THEN
    RAISE EXCEPTION 'NOT_ASSIGNED_CARRIER';
  END IF;

  IF v_method = 'PHOTO' AND p_photo_path IS NULL THEN
    RAISE EXCEPTION 'PHOTO_PATH_REQUIRED';
  END IF;

  -- Conservative quality ladder (see this file's header): a code-based
  -- handshake with the counterparty is STRONG; a bare photo is WEAK unless
  -- the device itself flags a mock location, which is SUSPECT.
  v_quality := CASE
    WHEN v_method IN ('QR','OTP','ADMIN_OVERRIDE') THEN 'STRONG'
    WHEN v_method = 'PHOTO' AND p_is_mock_location THEN 'SUSPECT'
    ELSE 'WEAK'
  END;

  INSERT INTO public.proofs
    (delivery_id, leg, method, quality, photo_path, geog, geo_accuracy_m,
     captured_at, is_offline_capture)
  VALUES
    (p_delivery, v_leg, v_method, v_quality, p_photo_path,
     CASE WHEN p_lat IS NOT NULL AND p_lng IS NOT NULL
          THEN public.ST_MakePoint(p_lng, p_lat)::public.geography ELSE NULL END,
     p_geo_accuracy_m, p_captured_at, p_is_offline_capture)
  ON CONFLICT (delivery_id, leg) DO UPDATE SET
    method = EXCLUDED.method, quality = EXCLUDED.quality,
    photo_path = EXCLUDED.photo_path, geog = EXCLUDED.geog,
    geo_accuracy_m = EXCLUDED.geo_accuracy_m, captured_at = EXCLUDED.captured_at,
    verified_at = now(), is_offline_capture = EXCLUDED.is_offline_capture
  RETURNING * INTO v_proof;

  RETURN jsonb_build_object(
    'proof_id', v_proof.id, 'leg', v_proof.leg, 'quality', v_proof.quality);
END $$;

REVOKE ALL ON FUNCTION
  public.rpc_submit_proof(UUID,TEXT,TEXT,TIMESTAMPTZ,TEXT,DOUBLE PRECISION,DOUBLE PRECISION,INT,BOOLEAN,BOOLEAN)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.rpc_submit_proof(UUID,TEXT,TEXT,TIMESTAMPTZ,TEXT,DOUBLE PRECISION,DOUBLE PRECISION,INT,BOOLEAN,BOOLEAN)
TO authenticated;

-- ── The actual gate: enforce requires_proof ─────────────────────────────────
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
  -- The fix: this was SELECTed into `rule` and never read again.
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

  -- BR-907: recipient confirmation is the primary escrow release trigger.
  IF p_event = 'CONFIRM_RECEIPT' THEN
    PERFORM internal.fn_settle_delivery(p_delivery);
  END IF;

  RETURN rule.to_status;
END $$;
