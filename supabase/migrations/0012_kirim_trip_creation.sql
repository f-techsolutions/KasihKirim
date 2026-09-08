-- ============================================================================
-- KasihKirim — 0012_kirim_trip_creation.sql
--
-- Closes the two gaps CLAUDE_IMPLEMENTATION_PLAN.md §3 flagged as blocking:
--   "No rpc_create_kirim | Customer cannot submit a Kirim"
--   "No rpc_create_trip  | Carrier cannot announce"
--
-- Same SECURITY DEFINER wrapper shape as 0005_rpc_surface.sql, for the same
-- reason: kirim_insert's own RLS policy only allows a direct INSERT while
-- status='DRAFT' (0003), and there is no policy path from DRAFT to POSTED --
-- so posting a Kirim genuinely needs a narrow, audited bridge, not a raw
-- PostgREST call. trips_insert has no such status restriction, but an
-- unmediated INSERT would let a carrier set capacity_weight_grams /
-- capacity_volume_cm3 / capacity_parcels to anything, unrelated to the
-- vehicle actually being used -- the same overclaiming risk BR-903 exists to
-- prevent. rpc_create_trip derives capacity from the vehicle row itself so a
-- client cannot state it.
--
-- RULE (restated from 0005): every function here REVOKEs from PUBLIC first,
-- then grants narrowly. Postgres grants EXECUTE to PUBLIC by default on every
-- newly created function.
-- ============================================================================

-- ── internal.fn_quote_kirim: capture what rpc_create_kirim needs later ──────
-- category_id, volume_cm3 and payment_method were resolved (or defaulted) at
-- quote time but never persisted -- input_snapshot only kept type/weight/
-- budget/origin/dest/flags. Re-supplying them at creation time would let a
-- client submit a Kirim priced for one category/volume/payment_method and
-- persisted with another, which is exactly the "no client pricing" hole §30
-- exists to close. Extending the snapshot instead makes the quote the single
-- source of truth for both calls. rpc_quote_kirim's external JSON response is
-- unchanged -- it never read input_snapshot -- so this is invisible to the
-- already-shipped Android quote flow (Phase 3).
CREATE OR REPLACE FUNCTION internal.fn_quote_kirim(
  p_type ref.kirim_type, p_category UUID, p_weight_g INT, p_volume_cm3 INT,
  p_budget_sen BIGINT, p_origin UUID, p_dest UUID,
  p_flags ref.handling_flag[], p_method ref.payment_method, p_requester UUID)
RETURNS internal.quotes LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  r internal.pricing_rules; p JSONB; km NUMERIC; band TEXT;
  base BIGINT; bandfee BIGINT; wfee BIGINT; hfee BIGINT := 0; codfee BIGINT := 0;
  billable_kg NUMERIC; delivery BIGINT; goods BIGINT; total BIGINT;
  comm BIGINT; crule internal.commission_rules; f ref.handling_flag; q internal.quotes;
BEGIN
  SELECT * INTO r FROM internal.pricing_rules
   WHERE effective_from <= now() AND (effective_to IS NULL OR effective_to > now())
   ORDER BY version DESC LIMIT 1;
  p := r.params;

  SELECT distance_km INTO km FROM ref.node_distance_matrix
   WHERE from_node_id = p_origin AND to_node_id = p_dest;
  km := COALESCE(km, 50);
  band := internal.fn_band_for(km, p);

  billable_kg := GREATEST(p_weight_g/1000.0,
                          p_volume_cm3::numeric / (p->>'volumetric_divisor')::numeric);
  base    := (p->>'base_fare_sen')::bigint;
  bandfee := (p->'corridor_band_sen'->>band)::bigint;
  wfee    := CEIL(GREATEST(0, billable_kg - (p->>'included_kg')::numeric))
             * (p->>'per_kg_sen')::bigint;
  FOREACH f IN ARRAY p_flags LOOP
    hfee := hfee + COALESCE((p->'handling_surcharge_sen'->>f::text)::bigint, 0);
  END LOOP;
  IF p_method = 'COD' THEN codfee := (p->>'cod_handling_sen')::bigint; END IF;

  delivery := base + bandfee + wfee + hfee + codfee;
  goods    := CASE WHEN p_type='BELI' THEN COALESCE(p_budget_sen,0) ELSE 0 END;
  total    := goods + delivery;

  SELECT * INTO crule FROM internal.commission_rules
   WHERE party='platform' AND effective_from <= now()
     AND (effective_to IS NULL OR effective_to > now()) ORDER BY effective_from DESC LIMIT 1;

  comm := CASE crule.basis
            WHEN 'order_total'  THEN total * crule.rate_bps / 10000
            WHEN 'delivery_fee' THEN delivery * crule.rate_bps / 10000
            WHEN 'goods_subtotal' THEN goods * crule.rate_bps / 10000
            ELSE crule.flat_sen END;
  IF crule.max_commission_sen IS NOT NULL THEN
    comm := LEAST(comm, crule.max_commission_sen);
  END IF;

  INSERT INTO internal.quotes (subject_type, requester_id, input_snapshot, breakdown,
    goods_budget_sen, delivery_fee_sen, commission_sen, total_sen,
    pricing_rule_version, corridor_km, corridor_band, expires_at)
  VALUES ('kirim', p_requester,
    jsonb_build_object('type',p_type,'category',p_category,'weight_g',p_weight_g,
                       'volume_cm3',p_volume_cm3,'budget',p_budget_sen,
                       'origin',p_origin,'dest',p_dest,'flags',p_flags,
                       'payment_method',p_method),
    jsonb_build_object('base',base,'band',bandfee,'band_name',band,'weight',wfee,
                       'handling',hfee,'cod',codfee),
    goods, delivery, comm, total, r.version, km, band,
    now() + ((SELECT (value#>>'{}')::int FROM ref.app_config WHERE key='quote_ttl_minutes')
             ||' minutes')::interval)
  RETURNING * INTO q;
  RETURN q;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- rpc_create_kirim — consume a quote, post the Kirim.
-- ════════════════════════════════════════════════════════════════════════════
CREATE SEQUENCE IF NOT EXISTS internal.kirim_reference_seq START 1000;

/** Submits a Kirim from a previously obtained quote. Everything that affects
 *  price (type, category, weight, volume, corridor, handling, payment
 *  method) is read from the quote, never re-supplied here -- a client cannot
 *  submit a Kirim priced for one set of inputs and persisted with another. */
CREATE OR REPLACE FUNCTION public.rpc_create_kirim(
  p_quote_id           UUID,
  p_item_description   TEXT,
  p_dest_address_id    UUID,
  p_origin_address_id  UUID DEFAULT NULL,
  p_photo_paths        TEXT[] DEFAULT '{}',
  p_declared_value_sen BIGINT DEFAULT NULL,
  p_pickup_date        DATE DEFAULT NULL,
  p_pickup_window      TEXT DEFAULT NULL,
  p_deliver_by_date    DATE DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  q internal.quotes; v_uid UUID := auth.uid();
  v_type ref.kirim_type; v_category UUID; v_weight INT; v_volume INT;
  v_origin UUID; v_dest UUID; v_flags ref.handling_flag[]; v_method ref.payment_method;
  v_budget BIGINT; v_kirim UUID; v_ref TEXT; v_expires TIMESTAMPTZ;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO q FROM internal.quotes WHERE id = p_quote_id FOR UPDATE;
  IF NOT FOUND OR q.subject_type <> 'kirim' OR q.requester_id <> v_uid THEN
    RAISE EXCEPTION 'QUOTE_NOT_FOUND';
  END IF;
  IF q.consumed_at IS NOT NULL THEN RAISE EXCEPTION 'QUOTE_ALREADY_CONSUMED'; END IF;
  IF q.expires_at < now() THEN RAISE EXCEPTION 'QUOTE_EXPIRED'; END IF;

  v_type    := (q.input_snapshot->>'type')::ref.kirim_type;
  v_category:= (q.input_snapshot->>'category')::uuid;
  v_weight  := (q.input_snapshot->>'weight_g')::int;
  v_volume  := (q.input_snapshot->>'volume_cm3')::int;
  v_origin  := (q.input_snapshot->>'origin')::uuid;
  v_dest    := (q.input_snapshot->>'dest')::uuid;
  v_method  := (q.input_snapshot->>'payment_method')::ref.payment_method;
  v_flags   := ARRAY(SELECT jsonb_array_elements_text(q.input_snapshot->'flags'))::ref.handling_flag[];
  v_budget  := CASE WHEN v_type = 'BELI' THEN q.goods_budget_sen ELSE NULL END;

  IF v_type = 'BELI' AND COALESCE(v_budget,0) <= 0 THEN
    RAISE EXCEPTION 'BELI_REQUIRES_BUDGET';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.addresses
                 WHERE id = p_dest_address_id AND user_id = v_uid AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'ADDRESS_NOT_FOUND';
  END IF;
  -- ck_hantar_has_origin (0001): HANTAR needs a pickup address; other types
  -- don't require one, but an address given must still be the caller's own.
  IF v_type = 'HANTAR' THEN
    IF p_origin_address_id IS NULL THEN RAISE EXCEPTION 'ORIGIN_ADDRESS_REQUIRED'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.addresses
                   WHERE id = p_origin_address_id AND user_id = v_uid AND deleted_at IS NULL) THEN
      RAISE EXCEPTION 'ADDRESS_NOT_FOUND';
    END IF;
  ELSIF p_origin_address_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM public.addresses
                        WHERE id = p_origin_address_id AND user_id = v_uid AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'ADDRESS_NOT_FOUND';
  END IF;

  v_ref := 'KK-' || to_char(now(),'YYMM') || '-'
           || lpad(nextval('internal.kirim_reference_seq')::text, 6, '0');
  v_expires := now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                         WHERE key='kirim_board_ttl_hours') || ' hours')::interval;

  INSERT INTO public.kirim_requests (
    reference_code, requester_id, kirim_type, status, item_description, category_id,
    est_weight_grams, volume_cm3, handling_flags, photo_paths, declared_value_sen,
    budget_cap_sen, origin_address_id, dest_address_id, origin_node_id, dest_node_id,
    pickup_date, pickup_window, deliver_by_date, quote_id, delivery_fee_sen,
    commission_sen, total_escrow_sen, payment_method, expires_at)
  VALUES (
    v_ref, v_uid, v_type, 'POSTED', p_item_description, v_category,
    v_weight, v_volume, v_flags, p_photo_paths, p_declared_value_sen,
    v_budget, p_origin_address_id, p_dest_address_id, v_origin, v_dest,
    p_pickup_date, p_pickup_window, p_deliver_by_date, p_quote_id, q.delivery_fee_sen,
    q.commission_sen, q.total_sen, v_method, v_expires)
  RETURNING id INTO v_kirim;

  UPDATE internal.quotes SET consumed_at = now() WHERE id = p_quote_id;

  RETURN jsonb_build_object(
    'kirim_id', v_kirim, 'reference_code', v_ref, 'status', 'POSTED',
    'expires_at', v_expires);
END $$;

INSERT INTO ref.app_config (key, value, description) VALUES
  ('kirim_board_ttl_hours', '72', 'How long a POSTED kirim stays visible on the board')
ON CONFLICT (key) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- rpc_create_trip — a carrier announces capacity.
-- ════════════════════════════════════════════════════════════════════════════

/** Announces a trip. capacity_* is read from the vehicle row, never taken
 *  from the caller: trips_insert (0003) has no status restriction, so an
 *  unmediated PostgREST insert would let a carrier claim any capacity
 *  unrelated to the vehicle actually making the run. */
CREATE OR REPLACE FUNCTION public.rpc_create_trip(
  p_vehicle_id            UUID,
  p_origin_node           UUID,
  p_dest_node             UUID,
  p_depart_at             TIMESTAMPTZ,
  p_corridor_nodes        UUID[] DEFAULT NULL,
  p_depart_window_minutes INT DEFAULT 120,
  -- TEXT[], not ref.handling_flag[], matching rpc_quote_kirim's p_handling_flags
  -- (0005): cast explicitly inside the body rather than asking PostgREST to
  -- coerce a JSON array straight into a custom enum array type.
  p_handling_capabilities TEXT[] DEFAULT NULL,
  p_accepts_cod           BOOLEAN DEFAULT true,
  p_accepts_beli          BOOLEAN DEFAULT true)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_carrier UUID := authz.my_carrier_id(); v_vehicle public.vehicles; v_trip UUID;
BEGIN
  IF v_carrier IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO v_vehicle FROM public.vehicles
   WHERE id = p_vehicle_id AND carrier_id = v_carrier;
  IF NOT FOUND OR NOT v_vehicle.is_active THEN RAISE EXCEPTION 'VEHICLE_NOT_FOUND'; END IF;

  IF p_origin_node = p_dest_node THEN RAISE EXCEPTION 'INVALID_CORRIDOR'; END IF;
  IF p_depart_at <= now() THEN RAISE EXCEPTION 'DEPART_TIME_IN_PAST'; END IF;

  INSERT INTO public.trips (
    carrier_id, vehicle_id, status, origin_node_id, dest_node_id, corridor_nodes,
    depart_at, depart_window_minutes, capacity_weight_grams, capacity_volume_cm3,
    capacity_parcels, handling_capabilities, accepts_cod, accepts_beli)
  VALUES (
    v_carrier, p_vehicle_id, 'ANNOUNCED', p_origin_node, p_dest_node,
    COALESCE(p_corridor_nodes, ARRAY[p_origin_node, p_dest_node]),
    p_depart_at, p_depart_window_minutes,
    v_vehicle.capacity_weight_grams, v_vehicle.capacity_volume_cm3, v_vehicle.capacity_parcels,
    COALESCE(p_handling_capabilities::ref.handling_flag[], v_vehicle.handling_capabilities),
    p_accepts_cod, p_accepts_beli)
  RETURNING id INTO v_trip;

  RETURN jsonb_build_object(
    'trip_id', v_trip, 'status', 'ANNOUNCED',
    'capacity_weight_grams', v_vehicle.capacity_weight_grams,
    'capacity_volume_cm3', v_vehicle.capacity_volume_cm3,
    'capacity_parcels', v_vehicle.capacity_parcels);
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- GRANTS — revoke first, then grant narrowly (see header).
-- ════════════════════════════════════════════════════════════════════════════
REVOKE ALL ON FUNCTION
  public.rpc_create_kirim(UUID,TEXT,UUID,UUID,TEXT[],BIGINT,DATE,TEXT,DATE),
  public.rpc_create_trip(UUID,UUID,UUID,TIMESTAMPTZ,UUID[],INT,TEXT[],BOOLEAN,BOOLEAN)
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
  public.rpc_create_kirim(UUID,TEXT,UUID,UUID,TEXT[],BIGINT,DATE,TEXT,DATE),
  public.rpc_create_trip(UUID,UUID,UUID,TIMESTAMPTZ,UUID[],INT,TEXT[],BOOLEAN,BOOLEAN)
TO authenticated;
