-- ============================================================================
-- KasihKirim — 0005_rpc_surface.sql
--
-- WHY THIS FILE EXISTS
-- PostgREST's exposed-schema list is global. `internal` is not on it, so it is
-- unreachable over REST by EVERY role — including service_role. Edge Functions
-- calling admin.schema('internal') get a 404, not a permission error, which is
-- an easy bug to misdiagnose.
--
-- This is the deliberate bridge: a small, audited set of SECURITY DEFINER
-- wrappers in `public`, each granted to exactly the roles that need it. The
-- ledger stays unreachable; only these named operations cross the boundary.
--
-- RULE: every function here REVOKEs from PUBLIC first, then grants narrowly.
-- A wrapper with a default grant is a hole straight into the money layer.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- CALLABLE BY authenticated  (the RPC layer in API.md §1)
-- ════════════════════════════════════════════════════════════════════════════

/** Quote. The requester is taken from the JWT, never from an argument — a
 *  client cannot quote on someone else's behalf. */
CREATE OR REPLACE FUNCTION public.rpc_quote_kirim(
  p_kirim_type      TEXT,
  p_category_slug   TEXT,
  p_est_weight_grams INT,
  p_origin_node     UUID,
  p_dest_node       UUID,
  p_budget_cap_sen  BIGINT DEFAULT 0,
  p_volume_cm3      INT DEFAULT 8000,
  p_handling_flags  TEXT[] DEFAULT '{}',
  p_payment_method  TEXT DEFAULT 'COD')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE q internal.quotes; v_cat UUID; v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  IF p_budget_cap_sen > (SELECT (value#>>'{}')::bigint FROM ref.app_config
                          WHERE key='max_budget_cap_sen') THEN
    RAISE EXCEPTION 'BUDGET_CAP_EXCEEDED';
  END IF;

  SELECT id INTO v_cat FROM ref.categories WHERE slug = p_category_slug;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'CATEGORY_NOT_FOUND'; END IF;

  SELECT * INTO q FROM internal.fn_quote_kirim(
    p_kirim_type::ref.kirim_type, v_cat, p_est_weight_grams, p_volume_cm3,
    p_budget_cap_sen, p_origin_node, p_dest_node,
    p_handling_flags::ref.handling_flag[], p_payment_method::ref.payment_method,
    v_uid);

  -- carrier_earning is returned on purpose (FR-245): a carrier must see what
  -- they will earn before accepting. Hiding it breeds the mistrust this
  -- product exists to remove.
  RETURN jsonb_build_object(
    'quote_id', q.id,
    'expires_at', q.expires_at,
    'corridor_km', q.corridor_km,
    'corridor_band', q.corridor_band,
    'breakdown', q.breakdown,
    'goods_budget_sen', q.goods_budget_sen,
    'delivery_fee_sen', q.delivery_fee_sen,
    'commission_sen', q.commission_sen,
    'order_total_sen', q.total_sen,
    'carrier_earning_sen', q.delivery_fee_sen - q.commission_sen,
    'pricing_rule_version', q.pricing_rule_version);
END $$;

/** Accept an offer. The single most safety-critical write in the system:
 *  capacity lock, float check, delivery creation and handover codes all inside
 *  one transaction. There is no window in which two carriers win the last slot. */
CREATE OR REPLACE FUNCTION public.rpc_accept_offer(
  p_trip UUID, p_kirim UUID, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_carrier UUID := authz.my_carrier_id();
  k public.kirim_requests; q internal.quotes;
  v_res UUID; v_delivery UUID; v_advance BIGINT;
BEGIN
  IF v_carrier IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = p_kirim FOR UPDATE;
  IF NOT FOUND OR k.status <> 'POSTED' THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION';
  END IF;
  -- BR-910: a carrier cannot fulfil their own request.
  IF k.requester_id = auth.uid() THEN RAISE EXCEPTION 'SELF_DEALING'; END IF;

  -- BR-908 checked up front so the carrier gets a clear error rather than a
  -- raw constraint violation from deep inside the transaction.
  v_advance := COALESCE(k.budget_cap_sen, 0);
  IF EXISTS (SELECT 1 FROM public.carriers c WHERE c.id = v_carrier
             AND c.cod_held_sen + c.procurement_advance_sen + v_advance > c.float_limit_sen)
  THEN RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED'; END IF;

  v_res := internal.fn_reserve_capacity(
    p_trip, p_kirim, k.est_weight_grams, k.volume_cm3, 1);

  UPDATE public.trip_reservations SET status='CONFIRMED', expires_at=NULL
   WHERE id = v_res;

  SELECT * INTO q FROM internal.quotes WHERE id = k.quote_id;

  INSERT INTO public.deliveries (kirim_id, trip_id, carrier_id, reservation_id,
    status, cod_amount_sen, carrier_earning_sen, platform_fee_sen)
  VALUES (p_kirim, p_trip, v_carrier, v_res, 'MATCHED',
    CASE WHEN k.payment_method='COD' THEN COALESCE(q.total_sen,0) ELSE 0 END,
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

  RETURN jsonb_build_object('delivery_id', v_delivery, 'reservation_id', v_res,
                            'status','MATCHED');
END $$;

/** Delivery transition. Role is derived from the JWT, never from the payload. */
CREATE OR REPLACE FUNCTION public.rpc_delivery_transition(
  p_delivery UUID, p_event TEXT,
  p_idempotency_key TEXT DEFAULT NULL, p_meta JSONB DEFAULT '{}')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_role ref.user_role; v_new ref.kirim_status; v_roles TEXT[];
BEGIN
  v_roles := authz.user_roles();
  IF array_length(v_roles,1) IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  -- Pick the role that this specific transition permits, from the roles the
  -- user genuinely holds. A user cannot name a role they do not have.
  SELECT r::ref.user_role INTO v_role
  FROM unnest(v_roles) r
  JOIN public.deliveries d ON d.id = p_delivery
  JOIN ref.delivery_transition_rules t
    ON t.from_status = d.status AND t.event = p_event
  WHERE r::ref.user_role = ANY(t.allowed_roles)
  LIMIT 1;

  IF v_role IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  v_new := internal.fn_delivery_transition(
    p_delivery, p_event, auth.uid(), v_role, p_idempotency_key, p_meta);

  RETURN jsonb_build_object(
    'status', v_new,
    'next_events', COALESCE((SELECT jsonb_agg(event) FROM ref.delivery_transition_rules
                             WHERE from_status = v_new), '[]'::jsonb));
END $$;

/** Carrier earnings, derived from the ledger without exposing it. */
CREATE OR REPLACE FUNCTION public.rpc_my_earnings()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_carrier UUID := authz.my_carrier_id();
BEGIN
  IF v_carrier IS NULL THEN RETURN jsonb_build_object('available_sen',0,'pending_sen',0); END IF;
  RETURN (
    SELECT jsonb_build_object(
      'available_sen', COALESCE(SUM(d.carrier_earning_sen)
        FILTER (WHERE d.status='COMPLETED'),0),
      'pending_sen', COALESCE(SUM(d.carrier_earning_sen)
        FILTER (WHERE d.status IN ('PICKED_UP','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED')),0),
      'cod_held_sen', (SELECT cod_held_sen FROM public.carriers WHERE id=v_carrier),
      'float_limit_sen', (SELECT float_limit_sen FROM public.carriers WHERE id=v_carrier))
    FROM public.deliveries d WHERE d.carrier_id = v_carrier);
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- CALLABLE BY service_role ONLY  (Edge Functions)
-- ════════════════════════════════════════════════════════════════════════════

/** Insert-first webhook dedupe. Returns false when already seen, so the Edge
 *  Function can return 200 immediately without processing. */
CREATE OR REPLACE FUNCTION public.rpc_record_webhook(
  p_provider TEXT, p_event_id TEXT, p_signature_valid BOOLEAN, p_payload JSONB)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO internal.webhook_events
    (provider, provider_event_id, signature_valid, payload)
  VALUES (p_provider, p_event_id, p_signature_valid, p_payload);
  RETURN true;
EXCEPTION WHEN unique_violation THEN
  RETURN false;             -- already processed; idempotent by constraint
END $$;

CREATE OR REPLACE FUNCTION public.rpc_apply_payment_event(
  p_provider TEXT, p_event_id TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  RETURN internal.fn_apply_payment_event(p_provider, p_event_id)::text;
END $$;

/** Idempotency store. Returns the prior response on replay, or NULL to proceed.
 *  A different body under the same key returns a conflict marker. */
CREATE OR REPLACE FUNCTION public.rpc_idem_lookup(
  p_key TEXT, p_request_hash TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE r internal.idempotency_keys;
BEGIN
  SELECT * INTO r FROM internal.idempotency_keys WHERE key = p_key;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF r.request_hash <> p_request_hash THEN
    RETURN jsonb_build_object('conflict', true);
  END IF;
  RETURN jsonb_build_object('replayed', true,
    'status_code', r.status_code, 'response_body', r.response_body);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_idem_store(
  p_key TEXT, p_actor UUID, p_endpoint TEXT, p_request_hash TEXT,
  p_response JSONB, p_status INT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO internal.idempotency_keys
    (key, actor_id, endpoint, request_hash, response_body, status_code)
  VALUES (p_key, p_actor, p_endpoint, p_request_hash, p_response, p_status)
  ON CONFLICT (key) DO NOTHING;
END $$;

/** QR nonce consumption. First use wins — the unique index decides, not us. */
CREATE OR REPLACE FUNCTION public.rpc_consume_nonce(
  p_nonce TEXT, p_delivery UUID, p_leg TEXT, p_by UUID)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO internal.handover_nonces (nonce, delivery_id, leg, consumed_by)
  VALUES (p_nonce, p_delivery, p_leg::ref.handover_leg, p_by);
  RETURN true;
EXCEPTION WHEN unique_violation THEN
  RETURN false;             -- replay attempt
END $$;

CREATE OR REPLACE FUNCTION public.rpc_risk_signal(
  p_subject_type TEXT, p_subject_id UUID, p_signal TEXT,
  p_severity INT, p_details JSONB DEFAULT '{}')
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO internal.risk_signals
    (subject_type, subject_id, signal, severity, details)
  VALUES (p_subject_type, p_subject_id, p_signal, p_severity, p_details);
END $$;

CREATE OR REPLACE FUNCTION public.rpc_reconcile()
RETURNS JSONB LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$
  SELECT jsonb_agg(jsonb_build_object(
    'check', check_name, 'variance_sen', variance_sen, 'ok', ok))
  FROM internal.fn_reconcile();
$$;

-- ════════════════════════════════════════════════════════════════════════════
-- GRANTS — revoke first, then grant narrowly. A default grant here is a hole
-- straight into the money layer.
-- ════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname='public' AND p.proname LIKE 'rpc\_%'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
  END LOOP;
END $$;

-- User-callable
GRANT EXECUTE ON FUNCTION
  public.rpc_quote_kirim(TEXT,TEXT,INT,UUID,UUID,BIGINT,INT,TEXT[],TEXT),
  public.rpc_accept_offer(UUID,UUID,TEXT),
  public.rpc_delivery_transition(UUID,TEXT,TEXT,JSONB),
  public.rpc_my_earnings()
TO authenticated;

-- Edge Functions only. Never reachable with a user JWT.
GRANT EXECUTE ON FUNCTION
  public.rpc_record_webhook(TEXT,TEXT,BOOLEAN,JSONB),
  public.rpc_apply_payment_event(TEXT,TEXT),
  public.rpc_idem_lookup(TEXT,TEXT),
  public.rpc_idem_store(TEXT,UUID,TEXT,TEXT,JSONB,INT),
  public.rpc_consume_nonce(TEXT,UUID,TEXT,UUID),
  public.rpc_risk_signal(TEXT,UUID,TEXT,INT,JSONB),
  public.rpc_reconcile()
TO service_role;
