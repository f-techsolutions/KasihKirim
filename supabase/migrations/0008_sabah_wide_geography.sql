-- ============================================================================
-- KasihKirim — 0008_sabah_wide_geography.sql
--
-- SCOPE CORRECTION: KasihKirim is a SABAH-WIDE platform. Beluran and Paitan
-- are initial PILOT locations, not the product scope and not the root of the
-- geography.
--
-- Corrects four model defects found by audit:
--   1. No division level (Sabah has five administrative divisions).
--   2. Districts had no operational status — only service_areas did.
--      Requirement §2 puts activation status on the district.
--   3. Paitan was modelled as a DISTRICT. It is a sub-district of Beluran.
--      Requirement §10: Paitan must sit at its correct geographic level, not
--      be treated as a root location.
--   4. Transport types were a bare ENUM with no capability metadata, so the
--      routing and matching engine could not reason about water routes.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. DIVISIONS  (region → division → district → mukim → community)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE ref.divisions (
  id         UUID PRIMARY KEY DEFAULT uuidv7(),
  region_id  UUID NOT NULL REFERENCES ref.regions(id),
  code       TEXT NOT NULL UNIQUE,
  name       TEXT NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (region_id, name)
);

-- ════════════════════════════════════════════════════════════════════════════
-- 2. DISTRICT OPERATIONAL STATUS  (§2)
-- PLANNED → PILOT → ACTIVE, with two ways to close.
-- Changing this is an admin UPDATE. It must never require an Android release.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TYPE ref.district_status AS ENUM
  ('PLANNED','PILOT','ACTIVE','SUSPENDED','TEMPORARILY_UNAVAILABLE');

ALTER TABLE ref.districts
  ADD COLUMN division_id        UUID REFERENCES ref.divisions(id),
  -- §10: sub-districts (daerah kecil) such as Paitan sit UNDER a district.
  ADD COLUMN parent_district_id UUID REFERENCES ref.districts(id),
  ADD COLUMN is_sub_district    BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN status             ref.district_status NOT NULL DEFAULT 'PLANNED',
  ADD COLUMN status_reason      TEXT,
  ADD COLUMN status_changed_by  UUID REFERENCES public.profiles(id),
  ADD COLUMN status_changed_at  TIMESTAMPTZ,
  ADD COLUMN terrain_profile    TEXT[] NOT NULL DEFAULT '{}',
  ADD CONSTRAINT ck_sub_district_has_parent
    CHECK (NOT is_sub_district OR parent_district_id IS NOT NULL),
  ADD CONSTRAINT ck_district_not_own_parent
    CHECK (parent_district_id IS NULL OR parent_district_id <> id);

CREATE INDEX ix_districts_status ON ref.districts(status)
  WHERE status IN ('PILOT','ACTIVE');
CREATE INDEX ix_districts_parent ON ref.districts(parent_district_id)
  WHERE parent_district_id IS NOT NULL;

-- Status changes are audited. Opening a district is an operational decision
-- with commercial and compliance consequences, not a config tweak.
CREATE OR REPLACE FUNCTION internal.tg_audit_district_status()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO audit.audit_logs (actor_id, action, entity_type, entity_id,
                                  before, after, reason)
    VALUES (NEW.status_changed_by, 'DISTRICT_STATUS_CHANGE','district', NEW.id,
            jsonb_build_object('status', OLD.status),
            jsonb_build_object('status', NEW.status),
            NEW.status_reason);
    NEW.status_changed_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_district_status_audit BEFORE UPDATE ON ref.districts
  FOR EACH ROW EXECUTE FUNCTION internal.tg_audit_district_status();

-- ════════════════════════════════════════════════════════════════════════════
-- 3. TRANSPORT TYPE REGISTRY  (§5)
-- The ENUM stays as the column type — changing it would be a redesign for no
-- gain. This table carries the CAPABILITY METADATA the routing and matching
-- engine needs, which an ENUM cannot hold. Adding a type is:
--     ALTER TYPE ref.vehicle_type ADD VALUE 'FERRY';
--     INSERT INTO ref.transport_types ...;
-- No schema redesign, no application release.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE ref.transport_types (
  code                  ref.vehicle_type PRIMARY KEY,
  name_ms               TEXT NOT NULL,
  name_en               TEXT NOT NULL,
  medium                TEXT NOT NULL CHECK (medium IN ('land','water','air')),
  typical_capacity_grams INT NOT NULL,
  typical_capacity_cm3  INT NOT NULL,
  typical_parcels       INT NOT NULL,
  avg_speed_kmh         NUMERIC(5,1) NOT NULL,
  can_carry             ref.handling_flag[] NOT NULL DEFAULT '{}',
  requires_licence      BOOLEAN NOT NULL DEFAULT false,
  licence_authority     TEXT,
  weather_sensitive     BOOLEAN NOT NULL DEFAULT false,
  sort_order            INT NOT NULL DEFAULT 0,
  is_active             BOOLEAN NOT NULL DEFAULT true
);

INSERT INTO ref.transport_types (code,name_ms,name_en,medium,
  typical_capacity_grams,typical_capacity_cm3,typical_parcels,avg_speed_kmh,
  can_carry,requires_licence,licence_authority,weather_sensitive,sort_order) VALUES
 ('MOTORCYCLE','Motosikal','Motorcycle','land',   15000,  60000, 2, 45,
  '{DOCUMENTS,FRAGILE}', false, NULL, true, 1),
 ('CAR','Kereta','Car','land',                    50000, 400000, 6, 60,
  '{DOCUMENTS,FRAGILE,PERISHABLE}', false, NULL, false, 2),
 ('VAN','Van','Van','land',                      800000,4000000,30, 55,
  '{DOCUMENTS,FRAGILE,PERISHABLE,COLD_CHAIN,OVERSIZED}', true,
  'CVLB Sabah — LEGAL REVIEW REQUIRED', false, 3),
 ('PICKUP','Pikap','Pickup','land',              600000,2500000,20, 55,
  '{DOCUMENTS,FRAGILE,PERISHABLE,LIVE_ANIMAL,OVERSIZED}', false, NULL, true, 4),
 ('FOURWD','Pacuan 4 Roda','4WD','land',         500000,2000000,15, 40,
  '{DOCUMENTS,FRAGILE,PERISHABLE,LIVE_ANIMAL,OVERSIZED}', false, NULL, false, 5),
 ('LORRY','Lori','Lorry','land',                3000000,15000000,80, 50,
  '{DOCUMENTS,FRAGILE,PERISHABLE,COLD_CHAIN,LIVE_ANIMAL,OVERSIZED}', true,
  'CVLB Sabah — LEGAL REVIEW REQUIRED', false, 6),
 -- Water transport is first-class, not an afterthought: much of Sabah's
 -- coastal and riverine geography has no road alternative at all.
 ('BOAT','Bot','Boat','water',                    400000,1500000,12, 25,
  '{DOCUMENTS,FRAGILE,PERISHABLE,LIVE_ANIMAL}', true,
  'Marine Department / Sabah Ports — LEGAL REVIEW REQUIRED', true, 7)
ON CONFLICT (code) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. SERVICE AREA TRANSPORT CAPABILITY
-- A river service area is not servable by a lorry. Matching must know.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.service_areas
  ADD COLUMN supported_transport ref.vehicle_type[] NOT NULL
    DEFAULT '{MOTORCYCLE,CAR,PICKUP,FOURWD,VAN,LORRY}',
  ADD COLUMN terrain TEXT[] NOT NULL DEFAULT '{}',
  ADD COLUMN notes TEXT;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. ORIGIN → DESTINATION SERVICEABILITY  (§8)
-- The client asks the SERVER whether a lane is served. No application shall
-- ever contain `if district == 'Beluran'`.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_check_serviceability(
  p_origin_node UUID, p_dest_node UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o_district ref.districts; d_district ref.districts;
  o_area public.service_areas; d_area public.service_areas;
  v_route ref.node_distance_matrix; v_water BOOLEAN;
BEGIN
  SELECT d.* INTO o_district FROM ref.route_nodes n
    JOIN ref.districts d ON d.id = n.district_id WHERE n.id = p_origin_node;
  SELECT d.* INTO d_district FROM ref.route_nodes n
    JOIN ref.districts d ON d.id = n.district_id WHERE n.id = p_dest_node;

  IF o_district.id IS NULL OR d_district.id IS NULL THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','GEOGRAPHY_UNKNOWN');
  END IF;

  IF o_district.status NOT IN ('PILOT','ACTIVE') THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','ORIGIN_NOT_ACTIVE',
      'district', o_district.name, 'status', o_district.status);
  END IF;
  IF d_district.status NOT IN ('PILOT','ACTIVE') THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','DESTINATION_NOT_ACTIVE',
      'district', d_district.name, 'status', d_district.status);
  END IF;

  SELECT * INTO v_route FROM ref.node_distance_matrix
   WHERE from_node_id = p_origin_node AND to_node_id = p_dest_node;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('serviceable', false, 'reason','NO_ROUTE');
  END IF;

  -- Does any leg require water transport?
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

CREATE OR REPLACE FUNCTION public.rpc_check_serviceability(
  p_origin_node UUID, p_dest_node UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT internal.fn_check_serviceability(p_origin_node, p_dest_node);
$$;
REVOKE ALL ON FUNCTION public.rpc_check_serviceability(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_check_serviceability(UUID,UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 5a. DISTANCE MATRIX REBUILD
--
-- Naive all-pairs over the corridor graph. Trivial at this size, and the
-- curated distances it produces feed the pricing engine
-- (internal.fn_quote_kirim) and fn_check_serviceability above.
--
-- This lives in a MIGRATION, not in seed.sql, because it is permanent database
-- infrastructure rather than seed data. It previously sat in seed.sql and was
-- called 22 lines later in the same file; the Supabase CLI pipelines seed
-- statements, and pgx Parses every statement in a batch before Executing any,
-- so the call was name-resolved before the CREATE had run:
--     ERROR: function internal.fn_rebuild_distance_matrix() does not exist
-- Defining it here means it exists in the catalogue before seed.sql begins.
--
-- Dependencies, both created in 0001_schema.sql:
--     ref.route_edges           (graph input)
--     ref.node_distance_matrix  (target)
-- The only unqualified identifier in the body is the CTE alias `walk`, so
-- SECURITY DEFINER with SET search_path='' is safe as written.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_rebuild_distance_matrix()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n INT := 0;
BEGIN
  DELETE FROM ref.node_distance_matrix;
  WITH RECURSIVE walk AS (
    SELECT from_node_id AS src, to_node_id AS dst, distance_km AS km,
           typical_minutes AS mins, 1 AS hops, ARRAY[from_node_id,to_node_id] AS path
    FROM ref.route_edges WHERE is_active
    UNION ALL
    SELECT w.src, e.to_node_id, w.km + e.distance_km, w.mins + e.typical_minutes,
           w.hops + 1, w.path || e.to_node_id
    FROM walk w JOIN ref.route_edges e ON e.from_node_id = w.dst
    WHERE e.is_active AND NOT e.to_node_id = ANY(w.path) AND w.hops < 8
  )
  INSERT INTO ref.node_distance_matrix (from_node_id,to_node_id,distance_km,minutes,hop_count,path_nodes)
  SELECT DISTINCT ON (src,dst) src,dst,km,mins,hops,path
  FROM walk ORDER BY src,dst,km ASC;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 6. RLS
-- ════════════════════════════════════════════════════════════════════════════
GRANT SELECT ON ref.divisions, ref.transport_types TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON ref.divisions, ref.transport_types,
                                 ref.districts, ref.mukims
  FROM authenticated, anon;
