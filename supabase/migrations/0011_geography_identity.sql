-- ============================================================================
-- KasihKirim — 0011_geography_identity.sql
--
-- DEFECT: a known PLANNED district reported GEOGRAPHY_UNKNOWN.
--
-- internal.fn_check_serviceability resolved a district FROM a route_node. Only
-- the pilot-corridor nodes existed, so all 27 districts were known as
-- administrative geography but only a handful were resolvable as locations.
-- Sandakan -- a real, seeded, PLANNED district -- looked unmapped.
--
-- That conflates two different things:
--     geography IDENTITY  -- do we know this place?    (ref.districts)
--     graph COVERAGE      -- can we route to it yet?   (ref.route_edges)
--
-- This migration contains ONLY the function. The centroid values and the
-- representative-node generation are DATA and live in seed.sql, because
-- ref.districts is populated by the seed, which runs AFTER all migrations.
-- An earlier draft of this file performed those UPDATEs and INSERTs here and
-- would have silently affected ZERO rows -- the same defect already seen with
-- ref.category_compliance in 0007.
--
-- Resulting states, all distinguishable:
--     known + ACTIVE/PILOT + routable  -> serviceable
--     known + PLANNED                  -> DESTINATION_NOT_ACTIVE
--     known + ACTIVE but no edges      -> NO_ROUTE
--     genuinely unmapped input         -> GEOGRAPHY_UNKNOWN
--
-- No district name or code appears anywhere in this function. Opening a
-- district remains a configuration change, never an application release.
--
-- Centroids are identity/resolution infrastructure ONLY. ref.route_edges stays
-- the sole authoritative source of curated distance: a district with a
-- centroid but no edges yields NO_ROUTE, never a straight-line price.
-- ============================================================================

-- ── Serviceability: identity first, routability second ──────────────────────
CREATE OR REPLACE FUNCTION internal.fn_check_serviceability(
  p_origin_node UUID, p_dest_node UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o_district ref.districts; d_district ref.districts;
  v_route ref.node_distance_matrix; v_water BOOLEAN;
BEGIN
  -- STEP 1 - IDENTITY. Unresolvable input is genuinely unmapped geography.
  SELECT d.* INTO o_district FROM ref.route_nodes n
    JOIN ref.districts d ON d.id = n.district_id WHERE n.id = p_origin_node;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','GEOGRAPHY_UNKNOWN',
                              'side','origin');
  END IF;

  SELECT d.* INTO d_district FROM ref.route_nodes n
    JOIN ref.districts d ON d.id = n.district_id WHERE n.id = p_dest_node;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','GEOGRAPHY_UNKNOWN',
                              'side','destination');
  END IF;

  -- STEP 2 - ACTIVATION. Known geography that is not yet open reports its
  -- status, never "unknown". This is what makes progressive Sabah-wide
  -- rollout legible to a customer.
  IF o_district.status NOT IN ('PILOT','ACTIVE') THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','ORIGIN_NOT_ACTIVE',
      'district', o_district.name, 'status', o_district.status);
  END IF;
  IF d_district.status NOT IN ('PILOT','ACTIVE') THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','DESTINATION_NOT_ACTIVE',
      'district', d_district.name, 'status', d_district.status);
  END IF;

  -- STEP 3 - ROUTABILITY. Both districts are open, but the graph may not yet
  -- connect them. Distinct from both "unknown" and "not active".
  SELECT * INTO v_route FROM ref.node_distance_matrix
   WHERE from_node_id = p_origin_node AND to_node_id = p_dest_node;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','NO_ROUTE',
      'origin_district', o_district.name, 'dest_district', d_district.name);
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM ref.route_edges e
    WHERE e.min_vehicle_type = 'BOAT'
      AND e.from_node_id = ANY(v_route.path_nodes)
      AND e.to_node_id   = ANY(v_route.path_nodes)) INTO v_water;

  RETURN jsonb_build_object(
    'serviceable', true,
    'origin_district', o_district.name,
    'dest_district', d_district.name,
    'distance_km', v_route.distance_km,
    'est_minutes', v_route.minutes,
    'requires_water_transport', v_water,
    'hop_count', v_route.hop_count);
END $$;
