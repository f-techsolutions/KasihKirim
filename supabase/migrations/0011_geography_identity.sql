-- ============================================================================
-- KasihKirim — 0011_geography_identity.sql
--
-- DEFECT: a known PLANNED district reported GEOGRAPHY_UNKNOWN.
--
-- internal.fn_check_serviceability resolves a district FROM a route_node. Only
-- the 13 pilot-corridor nodes existed, so all 27 districts were "known" as
-- administrative geography but only a handful were resolvable as locations.
-- Sandakan -- a real, seeded, PLANNED district -- looked unmapped.
--
-- That conflates two different things:
--     geography IDENTITY  -- do we know this place?      (ref.districts)
--     graph COVERAGE      -- can we route to it yet?     (ref.route_edges)
--
-- The fix separates them. Every district gets a representative node, derived
-- FROM ref.districts rather than from a hardcoded list, so the three states
-- become distinguishable:
--
--     known + ACTIVE/PILOT + routable  -> serviceable
--     known + PLANNED                  -> DESTINATION_NOT_ACTIVE
--     known + ACTIVE but no edges      -> NO_ROUTE
--     genuinely unmapped input         -> GEOGRAPHY_UNKNOWN
--
-- No district name appears in any function. Adding a district still opens
-- service by configuration alone, with no application release.
-- ============================================================================

-- ── District centroids ──────────────────────────────────────────────────────
-- APPROXIMATE district-town coordinates, sufficient for nearest-node resolution
-- and status reporting. They are NOT used for pricing: ref.route_edges carries
-- the curated distances, and a district with no edges yields NO_ROUTE rather
-- than a fabricated price.
-- LOCAL VERIFICATION REQUIRED before go-live.
UPDATE ref.districts d SET centroid = v.geog
FROM (VALUES
  ('SBH-KK',  116.0735, 5.9804), ('SBH-KBD', 116.4300, 6.3500),
  ('SBH-PPR', 115.9300, 5.7300), ('SBH-PNP', 116.1100, 5.9200),
  ('SBH-PTT', 116.0700, 5.9000), ('SBH-RNU', 116.6667, 5.9500),
  ('SBH-TRN', 116.2264, 6.1775), ('SBH-BFT', 115.7500, 5.3500),
  ('SBH-KGU', 116.1600, 5.3400), ('SBH-KPY', 115.5800, 5.6000),
  ('SBH-NBW', 116.4500, 5.0600), ('SBH-SPT', 115.5500, 5.0900),
  ('SBH-TBN', 116.3600, 5.6700), ('SBH-TNM', 115.9500, 5.1300),
  ('SBH-KMR', 116.7500, 6.5000), ('SBH-KDT', 116.8400, 6.8800),
  ('SBH-PTS', 116.8300, 6.6500), ('SBH-BLR', 117.5333, 5.8667),
  ('SBH-KNB', 117.9000, 5.5000), ('SBH-SDK', 118.1200, 5.8400),
  ('SBH-TLP', 117.1333, 5.6333), ('SBH-TGD', 117.2000, 5.3500),
  ('SBH-KLB', 117.5000, 4.5000), ('SBH-KNK', 118.2500, 4.6800),
  ('SBH-LD',  118.3300, 5.0300), ('SBH-SMP', 118.6100, 4.4800),
  ('SBH-TWU', 117.8900, 4.2400), ('SBH-BLR-PTN', 117.2500, 6.2167)
) AS v(code, lng, lat)
CROSS JOIN LATERAL (SELECT ST_Point(v.lng, v.lat)::geography AS geog) g
WHERE d.code = v.code;

-- ── One representative node per district, generated from the districts table ─
-- Idempotent: skips any district that already has a node.
INSERT INTO ref.route_nodes (name, node_type, district, district_id, geog, is_major)
SELECT d.name,
       CASE WHEN 'urban' = ANY(d.terrain_profile) THEN 'bandar' ELSE 'pekan' END,
       d.name, d.id, d.centroid,
       'urban' = ANY(d.terrain_profile)
FROM ref.districts d
WHERE d.centroid IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM ref.route_nodes n WHERE n.district_id = d.id);

-- Backfill district_id on the pilot-corridor nodes seeded before 0008.
UPDATE ref.route_nodes n SET district_id = d.id
  FROM ref.districts d WHERE d.name = n.district AND n.district_id IS NULL;

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
