-- ============================================================================
-- KasihKirim — 0001_schema.sql
-- Requires 0000_prelude.sql (extensions, schemas, uuidv7, auth helpers).
-- Tables are ordered so the file applies cleanly from zero.
-- Circular FKs (profiles.home_community_id, addresses.agent_hub_id) are added
-- by ALTER after their targets exist — never inline.
-- ============================================================================

-- ── Enumerated types ────────────────────────────────────────────────────────
CREATE TYPE ref.user_role AS ENUM (
  'customer','seller','carrier','agent',
  'admin_support','admin_ops','admin_finance','admin_compliance','admin_super');

CREATE TYPE ref.account_status AS ENUM ('pending','active','suspended','banned','deleted');
CREATE TYPE ref.kirim_type     AS ENUM ('BELI','HANTAR','PASARAN');

CREATE TYPE ref.kirim_status AS ENUM (
  'DRAFT','POSTED','MATCHED','PROCURING','AWAITING_PICKUP','PICKED_UP',
  'IN_TRANSIT','AT_HUB','OUT_FOR_DELIVERY','DELIVERED','COMPLETED',
  'FAILED_PICKUP','FAILED_DELIVERY','PROCUREMENT_FAILED',
  'RETURNING','RETURNED','CANCELLED','EXPIRED','DISPUTED','REFUNDED');

CREATE TYPE ref.trip_status AS ENUM (
  'DRAFT','ANNOUNCED','BOARDING','DEPARTED','IN_PROGRESS','ARRIVED','CLOSED','CANCELLED');

CREATE TYPE ref.reservation_status AS ENUM ('HELD','CONFIRMED','RELEASED','CONSUMED');

CREATE TYPE ref.order_status AS ENUM (
  'CREATED','PENDING_PAYMENT','PAID','ACCEPTED','PREPARING','READY_FOR_PICKUP',
  'FULFILLED','SETTLED','PAYMENT_FAILED','EXPIRED','REJECTED_BY_SELLER',
  'CANCELLED','REFUNDED','PARTIALLY_REFUNDED');

CREATE TYPE ref.payment_status AS ENUM (
  'INITIATED','PENDING','AUTHORIZED','CAPTURED','SUCCEEDED','SETTLED',
  'FAILED','CANCELLED','EXPIRED','REFUND_PENDING','REFUNDED','PARTIALLY_REFUNDED',
  'COD_PENDING','COD_COLLECTED','COD_REMITTED','COD_SHORTFALL');

CREATE TYPE ref.payment_method AS ENUM (
  'FPX','DUITNOW_QR','TNG_EWALLET','GRABPAY','BOOST','SHOPEEPAY','CARD','COD','WALLET_CREDIT');

CREATE TYPE ref.payout_status AS ENUM (
  'REQUESTED','UNDER_REVIEW','APPROVED','REJECTED','BATCHED','PROCESSING','PAID','FAILED');

CREATE TYPE ref.ledger_direction AS ENUM ('DEBIT','CREDIT');
CREATE TYPE ref.account_class    AS ENUM ('ASSET','LIABILITY','REVENUE','EXPENSE','EQUITY');

CREATE TYPE ref.verification_status AS ENUM (
  'NOT_STARTED','SUBMITTED','UNDER_REVIEW','MORE_INFO_REQUIRED',
  'APPROVED','REJECTED','SUSPENDED','REVOKED');

CREATE TYPE ref.handover_leg  AS ENUM ('pickup','dropoff');
CREATE TYPE ref.proof_method  AS ENUM ('QR','OTP','AGENT','PHOTO','ADMIN_OVERRIDE');
CREATE TYPE ref.proof_quality AS ENUM ('STRONG','WEAK','SUSPECT');

CREATE TYPE ref.vehicle_type AS ENUM
  ('MOTORCYCLE','CAR','PICKUP','FOURWD','VAN','LORRY','BOAT');

CREATE TYPE ref.handling_flag AS ENUM
  ('FRAGILE','PERISHABLE','COLD_CHAIN','LIQUID','OVERSIZED','LIVE_ANIMAL','DOCUMENTS','HALAL_SEPARATE');

CREATE TYPE ref.dispute_status AS ENUM (
  'OPEN','UNDER_REVIEW','AWAITING_EVIDENCE','DECIDED',
  'RESOLVED_REFUND_FULL','RESOLVED_REFUND_PARTIAL','RESOLVED_REJECTED','RESOLVED_SPLIT','CLOSED');

CREATE TYPE ref.variance_status AS ENUM ('PENDING','APPROVED','REDUCED','DECLINED','TIMED_OUT');

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 1 — reference geography (no dependencies)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE ref.route_nodes (
  id         UUID PRIMARY KEY DEFAULT uuidv7(),
  name       TEXT NOT NULL,
  node_type  TEXT NOT NULL CHECK (node_type IN ('bandar','pekan','junction','kampung','jetty','hub')),
  district   TEXT NOT NULL,
  geog       GEOGRAPHY(POINT,4326) NOT NULL,
  is_major   BOOLEAN NOT NULL DEFAULT false,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_route_nodes_geog ON ref.route_nodes USING GIST(geog);

CREATE TABLE ref.route_edges (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  from_node_id     UUID NOT NULL REFERENCES ref.route_nodes(id),
  to_node_id       UUID NOT NULL REFERENCES ref.route_nodes(id),
  distance_km      NUMERIC(8,2) NOT NULL CHECK (distance_km > 0),
  typical_minutes  INT NOT NULL CHECK (typical_minutes > 0),
  road_quality     TEXT NOT NULL CHECK (road_quality IN ('sealed','gravel','logging','river','sea')),
  min_vehicle_type ref.vehicle_type NOT NULL DEFAULT 'CAR',
  is_seasonal      BOOLEAN NOT NULL DEFAULT false,
  seasonal_note    TEXT,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_node_id <> to_node_id),
  UNIQUE (from_node_id, to_node_id)
);

CREATE TABLE ref.node_distance_matrix (
  from_node_id UUID NOT NULL REFERENCES ref.route_nodes(id),
  to_node_id   UUID NOT NULL REFERENCES ref.route_nodes(id),
  distance_km  NUMERIC(8,2) NOT NULL,
  minutes      INT NOT NULL,
  hop_count    INT NOT NULL,
  path_nodes   UUID[] NOT NULL,
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (from_node_id, to_node_id)
);

CREATE TABLE ref.zones (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  name            TEXT NOT NULL,
  boundary        GEOGRAPHY(POLYGON,4326) NOT NULL,
  remoteness_tier INT NOT NULL CHECK (remoteness_tier BETWEEN 1 AND 5),
  surcharge_bps   INT NOT NULL DEFAULT 0 CHECK (surcharge_bps BETWEEN 0 AND 10000),
  is_serviceable  BOOLEAN NOT NULL DEFAULT true
);
CREATE INDEX ix_zones_boundary ON ref.zones USING GIST(boundary);

CREATE TABLE ref.categories (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  slug             TEXT NOT NULL UNIQUE,
  name_ms          TEXT NOT NULL,
  name_en          TEXT NOT NULL,
  parent_id        UUID REFERENCES ref.categories(id),
  icon             TEXT,
  default_handling ref.handling_flag[] NOT NULL DEFAULT '{}',
  sort_order       INT NOT NULL DEFAULT 0,
  is_active        BOOLEAN NOT NULL DEFAULT true
);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 2 — communities and identity
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.communities (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  name         TEXT NOT NULL,
  type         TEXT NOT NULL CHECK (type IN ('kampung','pekan','bandar','pulau')),
  district     TEXT NOT NULL,
  state        TEXT NOT NULL DEFAULT 'Sabah',
  geog         GEOGRAPHY(POINT,4326) NOT NULL,
  node_id      UUID REFERENCES ref.route_nodes(id),
  member_count INT NOT NULL DEFAULT 0,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (name, district, state)
);
CREATE INDEX ix_communities_geog ON public.communities USING GIST(geog);

CREATE TABLE public.profiles (
  id                   UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  phone                TEXT NOT NULL UNIQUE CHECK (phone ~ '^\+60[0-9]{8,10}$'),
  full_name            TEXT CHECK (length(full_name) BETWEEN 2 AND 120),
  display_name         TEXT CHECK (length(display_name) BETWEEN 2 AND 40),
  avatar_path          TEXT,
  preferred_language   TEXT NOT NULL DEFAULT 'ms' CHECK (preferred_language IN ('ms','en')),
  status               ref.account_status NOT NULL DEFAULT 'pending',
  home_community_id    UUID,                      -- FK added below
  nric_hash            TEXT,
  nric_last4           TEXT CHECK (nric_last4 ~ '^[0-9]{4}$'),
  rating_avg           NUMERIC(3,2) NOT NULL DEFAULT 0 CHECK (rating_avg BETWEEN 0 AND 5),
  rating_count         INT NOT NULL DEFAULT 0,
  kirim_sent_count     INT NOT NULL DEFAULT 0,
  kirim_received_count INT NOT NULL DEFAULT 0,
  suspended_reason     TEXT,
  deletion_requested_at TIMESTAMPTZ,
  anonymised_at        TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at           TIMESTAMPTZ
);
ALTER TABLE public.profiles
  ADD CONSTRAINT fk_profiles_home_community
  FOREIGN KEY (home_community_id) REFERENCES public.communities(id);

CREATE INDEX ix_profiles_updated   ON public.profiles(updated_at);
CREATE INDEX ix_profiles_community ON public.profiles(home_community_id) WHERE deleted_at IS NULL;
CREATE TRIGGER tg_profiles_touch BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION internal.tg_touch();

CREATE TABLE public.user_roles (
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role       ref.user_role NOT NULL,
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by UUID REFERENCES public.profiles(id),
  revoked_at TIMESTAMPTZ,
  PRIMARY KEY (user_id, role)
);
CREATE INDEX ix_user_roles_active ON public.user_roles(user_id) WHERE revoked_at IS NULL;

CREATE TABLE public.community_members (
  community_id UUID NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_primary   BOOLEAN NOT NULL DEFAULT false,
  PRIMARY KEY (community_id, user_id)
);
CREATE INDEX ix_community_members_user ON public.community_members(user_id);

CREATE TABLE public.devices (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  install_id      TEXT NOT NULL,
  expo_push_token TEXT,
  model           TEXT,
  os_version      TEXT,
  app_version     TEXT,
  total_ram_mb    INT,
  locale          TEXT,
  is_active       BOOLEAN NOT NULL DEFAULT true,
  last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, install_id)
);
CREATE INDEX ix_devices_push ON public.devices(expo_push_token) WHERE is_active;

CREATE TABLE public.addresses (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  label           TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 40),
  recipient_name  TEXT NOT NULL,
  recipient_phone TEXT NOT NULL CHECK (recipient_phone ~ '^\+60[0-9]{8,10}$'),
  community_id    UUID NOT NULL REFERENCES public.communities(id),
  landmark_note   TEXT NOT NULL CHECK (length(landmark_note) BETWEEN 3 AND 500),
  photo_path      TEXT,
  voice_note_path TEXT,
  line1           TEXT,
  postcode        TEXT CHECK (postcode IS NULL OR postcode ~ '^[0-9]{5}$'),
  district        TEXT,
  state           TEXT NOT NULL DEFAULT 'Sabah',
  geog            GEOGRAPHY(POINT,4326),
  geo_accuracy_m  INT,
  geo_captured_at TIMESTAMPTZ,
  nearest_node_id UUID REFERENCES ref.route_nodes(id),
  agent_hub_id    UUID,                        -- FK added in 0002
  delivery_notes  TEXT,
  is_default      BOOLEAN NOT NULL DEFAULT false,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ
);
CREATE UNIQUE INDEX ux_addresses_one_default
  ON public.addresses(user_id) WHERE is_default AND deleted_at IS NULL;
CREATE INDEX ix_addresses_geog ON public.addresses USING GIST(geog);
CREATE INDEX ix_addresses_node ON public.addresses(nearest_node_id);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 3 — carriers, vehicles, trips
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.carriers (
  id                      UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id                 UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status                  ref.verification_status NOT NULL DEFAULT 'NOT_STARTED',
  tier                    INT NOT NULL DEFAULT 1 CHECK (tier BETWEEN 1 AND 4),
  home_community_id       UUID REFERENCES public.communities(id),
  max_detour_km           NUMERIC(5,2) NOT NULL DEFAULT 10,
  float_limit_sen         BIGINT NOT NULL DEFAULT 50000 CHECK (float_limit_sen >= 0),
  cod_held_sen            BIGINT NOT NULL DEFAULT 0 CHECK (cod_held_sen >= 0),
  procurement_advance_sen BIGINT NOT NULL DEFAULT 0 CHECK (procurement_advance_sen >= 0),
  completed_count         INT NOT NULL DEFAULT 0,
  cancelled_count         INT NOT NULL DEFAULT 0,
  on_time_rate_bps        INT NOT NULL DEFAULT 10000,
  rating_avg              NUMERIC(3,2) NOT NULL DEFAULT 0,
  verified_at             TIMESTAMPTZ,
  suspended_until         TIMESTAMPTZ,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- BR-908: COD cash and BELI purchase advances draw on ONE limit.
  CONSTRAINT ck_carrier_exposure
    CHECK (cod_held_sen + procurement_advance_sen <= float_limit_sen)
);

CREATE TABLE public.vehicles (
  id                    UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id            UUID NOT NULL REFERENCES public.carriers(id) ON DELETE CASCADE,
  vehicle_type          ref.vehicle_type NOT NULL,
  plate_no              TEXT,
  make_model            TEXT,
  capacity_weight_grams INT NOT NULL CHECK (capacity_weight_grams > 0),
  capacity_volume_cm3   INT NOT NULL CHECK (capacity_volume_cm3 > 0),
  capacity_parcels      INT NOT NULL CHECK (capacity_parcels > 0),
  handling_capabilities ref.handling_flag[] NOT NULL DEFAULT '{}',
  photo_paths           TEXT[] NOT NULL DEFAULT '{}',
  insurance_expiry      DATE,
  road_tax_expiry       DATE,
  is_verified           BOOLEAN NOT NULL DEFAULT false,
  is_active             BOOLEAN NOT NULL DEFAULT true,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.trips (
  id                    UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id            UUID NOT NULL REFERENCES public.carriers(id) ON DELETE RESTRICT,
  vehicle_id            UUID NOT NULL REFERENCES public.vehicles(id),
  status                ref.trip_status NOT NULL DEFAULT 'DRAFT',
  origin_node_id        UUID NOT NULL REFERENCES ref.route_nodes(id),
  dest_node_id          UUID NOT NULL REFERENCES ref.route_nodes(id),
  corridor_nodes        UUID[] NOT NULL,
  depart_at             TIMESTAMPTZ NOT NULL,
  depart_window_minutes INT NOT NULL DEFAULT 120,
  arrive_est_at         TIMESTAMPTZ,
  capacity_weight_grams INT NOT NULL CHECK (capacity_weight_grams > 0),
  capacity_volume_cm3   INT NOT NULL CHECK (capacity_volume_cm3 > 0),
  capacity_parcels      INT NOT NULL CHECK (capacity_parcels > 0),
  reserved_weight_grams INT NOT NULL DEFAULT 0 CHECK (reserved_weight_grams >= 0),
  reserved_volume_cm3   INT NOT NULL DEFAULT 0 CHECK (reserved_volume_cm3 >= 0),
  reserved_parcels      INT NOT NULL DEFAULT 0 CHECK (reserved_parcels >= 0),
  handling_capabilities ref.handling_flag[] NOT NULL DEFAULT '{}',
  accepts_cod           BOOLEAN NOT NULL DEFAULT true,
  accepts_beli          BOOLEAN NOT NULL DEFAULT true,
  is_return_leg         BOOLEAN NOT NULL DEFAULT false,
  parent_trip_id        UUID REFERENCES public.trips(id),
  recurring_rule        TEXT,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- ═══ OVERBOOKING GUARD (BR-903, layer 2) ═══
  CONSTRAINT ck_trip_weight_capacity CHECK (reserved_weight_grams <= capacity_weight_grams),
  CONSTRAINT ck_trip_volume_capacity CHECK (reserved_volume_cm3   <= capacity_volume_cm3),
  CONSTRAINT ck_trip_parcel_capacity CHECK (reserved_parcels      <= capacity_parcels),
  CONSTRAINT ck_trip_distinct_ends   CHECK (origin_node_id <> dest_node_id)
);
CREATE INDEX ix_trips_matching ON public.trips (status, depart_at)
  WHERE status IN ('ANNOUNCED','BOARDING');
CREATE INDEX ix_trips_corridor ON public.trips USING GIN(corridor_nodes);
CREATE INDEX ix_trips_carrier  ON public.trips(carrier_id, depart_at DESC);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 4 — pricing and quotes (needed by kirim_requests)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE internal.pricing_rules (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  version        INT NOT NULL UNIQUE,
  params         JSONB NOT NULL,
  effective_from TIMESTAMPTZ NOT NULL,
  effective_to   TIMESTAMPTZ,
  created_by     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE TABLE internal.commission_rules (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  party              TEXT NOT NULL CHECK (party IN ('platform','agent','carrier')),
  basis              TEXT NOT NULL CHECK (basis IN ('order_total','goods_subtotal','delivery_fee','flat')),
  rate_bps           INT NOT NULL CHECK (rate_bps BETWEEN 0 AND 10000),
  flat_sen           BIGINT NOT NULL DEFAULT 0,
  max_commission_sen BIGINT,
  min_commission_sen BIGINT NOT NULL DEFAULT 0,
  kirim_type         ref.kirim_type,
  effective_from     TIMESTAMPTZ NOT NULL,
  effective_to       TIMESTAMPTZ
);

CREATE TABLE internal.quotes (
  id                   UUID PRIMARY KEY DEFAULT uuidv7(),
  subject_type         TEXT NOT NULL CHECK (subject_type IN ('kirim','order')),
  requester_id         UUID NOT NULL,
  input_snapshot       JSONB NOT NULL,
  breakdown            JSONB NOT NULL,
  goods_budget_sen     BIGINT NOT NULL DEFAULT 0,
  delivery_fee_sen     BIGINT NOT NULL,
  commission_sen       BIGINT NOT NULL,
  discount_sen         BIGINT NOT NULL DEFAULT 0,
  total_sen            BIGINT NOT NULL,
  pricing_rule_version INT NOT NULL REFERENCES internal.pricing_rules(version),
  corridor_km          NUMERIC(8,2),
  corridor_band        TEXT,
  expires_at           TIMESTAMPTZ NOT NULL,
  consumed_at          TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 5 — vouchers (referenced by kirim_requests)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.voucher_campaigns (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  code_prefix        TEXT NOT NULL,
  name               TEXT NOT NULL,
  discount_type      TEXT NOT NULL CHECK (discount_type IN ('fixed','percent')),
  discount_value     INT NOT NULL CHECK (discount_value > 0),
  max_discount_sen   BIGINT,
  min_order_sen      BIGINT NOT NULL DEFAULT 0,
  applies_to         ref.kirim_type[],
  budget_ceiling_sen BIGINT NOT NULL,
  budget_spent_sen   BIGINT NOT NULL DEFAULT 0,
  per_user_limit     INT NOT NULL DEFAULT 1,
  starts_at          TIMESTAMPTZ NOT NULL,
  ends_at            TIMESTAMPTZ NOT NULL,
  is_active          BOOLEAN NOT NULL DEFAULT true,
  CONSTRAINT ck_campaign_budget CHECK (budget_spent_sen <= budget_ceiling_sen)
);

CREATE TABLE public.voucher_issuances (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  campaign_id  UUID NOT NULL REFERENCES public.voucher_campaigns(id),
  user_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  code         TEXT NOT NULL UNIQUE,
  redeemed_at  TIMESTAMPTZ,
  redeemed_ref UUID,
  expires_at   TIMESTAMPTZ NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 6 — marketplace (orders referenced by kirim_requests)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.sellers (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id        UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE RESTRICT,
  business_name  TEXT NOT NULL,
  ssm_reg_no     TEXT,
  community_id   UUID NOT NULL REFERENCES public.communities(id),
  status         ref.verification_status NOT NULL DEFAULT 'NOT_STARTED',
  tier           INT NOT NULL DEFAULT 1,
  commission_bps INT CHECK (commission_bps BETWEEN 0 AND 10000),
  rating_avg     NUMERIC(3,2) NOT NULL DEFAULT 0,
  verified_at    TIMESTAMPTZ,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  seller_id        UUID NOT NULL REFERENCES public.sellers(id) ON DELETE RESTRICT,
  title            TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
  description      TEXT,
  category_id      UUID NOT NULL REFERENCES ref.categories(id),
  status           TEXT NOT NULL DEFAULT 'draft'
                     CHECK (status IN ('draft','pending_review','active','paused','rejected','delisted')),
  price_sen        BIGINT NOT NULL CHECK (price_sen > 0),
  unit             TEXT NOT NULL DEFAULT 'kg',
  weight_grams     INT NOT NULL CHECK (weight_grams > 0),
  volume_cm3       INT NOT NULL DEFAULT 8000,
  handling_flags   ref.handling_flag[] NOT NULL DEFAULT '{}',
  min_order_qty    INT NOT NULL DEFAULT 1,
  rejection_reason TEXT,
  search_vector    TSVECTOR GENERATED ALWAYS AS (
                     to_tsvector('simple', coalesce(title,'') || ' ' || coalesce(description,''))
                   ) STORED,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at       TIMESTAMPTZ
);
CREATE INDEX ix_products_search ON public.products USING GIN(search_vector);
CREATE INDEX ix_products_browse ON public.products(category_id, created_at DESC)
  WHERE status = 'active' AND deleted_at IS NULL;

CREATE TABLE public.product_images (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  product_id   UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  sort_order   INT NOT NULL DEFAULT 0,
  width INT, height INT, bytes INT CHECK (bytes <= 300000),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.inventory (
  product_id   UUID PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  on_hand      INT NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
  reserved     INT NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  safety_stock INT NOT NULL DEFAULT 0,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_inventory_not_oversold CHECK (reserved <= on_hand)
);

CREATE TABLE public.inventory_movements (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  product_id   UUID NOT NULL REFERENCES public.products(id),
  delta        INT NOT NULL,
  reason       TEXT NOT NULL,
  reference_id UUID,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by   UUID REFERENCES public.profiles(id)
);

CREATE TABLE public.orders (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  order_group_id     UUID NOT NULL,
  reference_code     TEXT NOT NULL UNIQUE,
  buyer_id           UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  seller_id          UUID NOT NULL REFERENCES public.sellers(id) ON DELETE RESTRICT,
  status             ref.order_status NOT NULL DEFAULT 'CREATED',
  goods_subtotal_sen BIGINT NOT NULL CHECK (goods_subtotal_sen >= 0),
  delivery_fee_sen   BIGINT NOT NULL DEFAULT 0,
  discount_sen       BIGINT NOT NULL DEFAULT 0,
  commission_sen     BIGINT NOT NULL DEFAULT 0,
  total_sen          BIGINT NOT NULL CHECK (total_sen >= 0),
  currency           TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
  payment_method     ref.payment_method,
  quote_id           UUID REFERENCES internal.quotes(id),
  address_snapshot   JSONB NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_order_total
    CHECK (total_sen = goods_subtotal_sen + delivery_fee_sen - discount_sen)
);

CREATE TABLE public.order_items (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  order_id       UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id     UUID NOT NULL REFERENCES public.products(id),
  title_snapshot TEXT NOT NULL,
  price_sen      BIGINT NOT NULL CHECK (price_sen > 0),
  quantity       INT NOT NULL CHECK (quantity > 0),
  weight_grams   INT NOT NULL,
  line_total_sen BIGINT NOT NULL,
  CONSTRAINT ck_line_total CHECK (line_total_sen = price_sen * quantity)
);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 7 — Kirim, deliveries, handover
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.kirim_requests (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  reference_code     TEXT NOT NULL UNIQUE,
  requester_id       UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  kirim_type         ref.kirim_type NOT NULL,
  status             ref.kirim_status NOT NULL DEFAULT 'DRAFT',
  item_description   TEXT NOT NULL CHECK (length(item_description) BETWEEN 3 AND 500),
  category_id        UUID NOT NULL REFERENCES ref.categories(id),
  est_weight_grams   INT NOT NULL CHECK (est_weight_grams BETWEEN 100 AND 500000),
  actual_weight_grams INT,
  volume_cm3         INT NOT NULL DEFAULT 8000,
  handling_flags     ref.handling_flag[] NOT NULL DEFAULT '{}',
  photo_paths        TEXT[] NOT NULL DEFAULT '{}',
  declared_value_sen BIGINT CHECK (declared_value_sen >= 0),
  budget_cap_sen     BIGINT CHECK (budget_cap_sen > 0),
  actual_goods_sen   BIGINT CHECK (actual_goods_sen >= 0),
  goods_receipt_path TEXT,
  goods_purchased_at TIMESTAMPTZ,
  origin_address_id  UUID REFERENCES public.addresses(id),
  dest_address_id    UUID NOT NULL REFERENCES public.addresses(id),
  origin_node_id     UUID NOT NULL REFERENCES ref.route_nodes(id),
  dest_node_id       UUID NOT NULL REFERENCES ref.route_nodes(id),
  pickup_date        DATE,
  pickup_window      TEXT CHECK (pickup_window IN ('pagi','tengahari','petang','malam')),
  deliver_by_date    DATE,
  quote_id           UUID REFERENCES internal.quotes(id),
  delivery_fee_sen   BIGINT CHECK (delivery_fee_sen >= 0),
  commission_sen     BIGINT CHECK (commission_sen >= 0),
  total_escrow_sen   BIGINT CHECK (total_escrow_sen >= 0),
  payment_method     ref.payment_method,
  voucher_id         UUID REFERENCES public.voucher_issuances(id),
  discount_sen       BIGINT NOT NULL DEFAULT 0 CHECK (discount_sen >= 0),
  order_id           UUID REFERENCES public.orders(id),
  visibility         TEXT NOT NULL DEFAULT 'board' CHECK (visibility IN ('board','direct')),
  expires_at         TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at         TIMESTAMPTZ,
  CONSTRAINT ck_beli_has_budget      CHECK (kirim_type <> 'BELI'   OR budget_cap_sen IS NOT NULL),
  CONSTRAINT ck_beli_budget_ceiling  CHECK (budget_cap_sen IS NULL OR budget_cap_sen <= 25000),
  CONSTRAINT ck_hantar_has_origin    CHECK (kirim_type <> 'HANTAR' OR origin_address_id IS NOT NULL),
  CONSTRAINT ck_pasaran_has_order    CHECK (kirim_type <> 'PASARAN' OR order_id IS NOT NULL),
  CONSTRAINT ck_distinct_nodes       CHECK (origin_node_id <> dest_node_id)
);
CREATE INDEX ix_kirim_board ON public.kirim_requests (status, created_at DESC)
  WHERE status = 'POSTED' AND deleted_at IS NULL;
CREATE INDEX ix_kirim_nodes     ON public.kirim_requests(origin_node_id, dest_node_id) WHERE status = 'POSTED';
CREATE INDEX ix_kirim_requester ON public.kirim_requests(requester_id, created_at DESC);
CREATE INDEX ix_kirim_updated   ON public.kirim_requests(updated_at);
CREATE INDEX ix_kirim_expiry    ON public.kirim_requests(expires_at) WHERE status = 'POSTED';

CREATE TABLE public.trip_reservations (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  trip_id       UUID NOT NULL REFERENCES public.trips(id) ON DELETE RESTRICT,
  kirim_id      UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  status        ref.reservation_status NOT NULL DEFAULT 'HELD',
  weight_grams  INT NOT NULL CHECK (weight_grams > 0),
  volume_cm3    INT NOT NULL CHECK (volume_cm3 > 0),
  parcels       INT NOT NULL DEFAULT 1 CHECK (parcels > 0),
  stop_sequence INT,
  expires_at    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  released_at   TIMESTAMPTZ,
  CHECK (status <> 'HELD' OR expires_at IS NOT NULL)
);
CREATE UNIQUE INDEX ux_reservation_active_kirim
  ON public.trip_reservations(kirim_id) WHERE status IN ('HELD','CONFIRMED');
CREATE INDEX ix_reservation_expiry ON public.trip_reservations(expires_at) WHERE status = 'HELD';

CREATE TABLE public.price_variances (
  id                   UUID PRIMARY KEY DEFAULT uuidv7(),
  kirim_id             UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  raised_by            UUID NOT NULL REFERENCES public.profiles(id),
  status               ref.variance_status NOT NULL DEFAULT 'PENDING',
  original_cap_sen     BIGINT NOT NULL,
  market_price_sen     BIGINT NOT NULL CHECK (market_price_sen > 0),
  requested_amount_sen BIGINT NOT NULL,
  approved_amount_sen  BIGINT,
  evidence_photo_path  TEXT NOT NULL,
  carrier_note         TEXT,
  requester_note       TEXT,
  responded_by         UUID REFERENCES public.profiles(id),
  responded_at         TIMESTAMPTZ,
  expires_at           TIMESTAMPTZ NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status <> 'APPROVED' OR approved_amount_sen IS NOT NULL)
);
CREATE UNIQUE INDEX ux_variance_one_pending
  ON public.price_variances(kirim_id) WHERE status = 'PENDING';
CREATE INDEX ix_variance_expiry ON public.price_variances(expires_at) WHERE status = 'PENDING';

CREATE TABLE public.deliveries (
  id                     UUID PRIMARY KEY DEFAULT uuidv7(),
  kirim_id               UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  trip_id                UUID REFERENCES public.trips(id),
  carrier_id             UUID NOT NULL REFERENCES public.carriers(id),
  reservation_id         UUID REFERENCES public.trip_reservations(id),
  attempt_no             INT NOT NULL DEFAULT 1,
  status                 ref.kirim_status NOT NULL DEFAULT 'MATCHED',
  cod_amount_sen         BIGINT NOT NULL DEFAULT 0 CHECK (cod_amount_sen >= 0),
  carrier_earning_sen    BIGINT CHECK (carrier_earning_sen >= 0),
  agent_fee_sen          BIGINT NOT NULL DEFAULT 0,
  platform_fee_sen       BIGINT CHECK (platform_fee_sen >= 0),
  matched_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  picked_up_at           TIMESTAMPTZ,
  delivered_at           TIMESTAMPTZ,
  recipient_confirmed_at TIMESTAMPTZ,
  completed_at           TIMESTAMPTZ,
  settlement_due_at      TIMESTAMPTZ,
  pickup_proof_quality   ref.proof_quality,
  dropoff_proof_quality  ref.proof_quality,
  failure_reason         TEXT,
  retry_count            INT NOT NULL DEFAULT 0 CHECK (retry_count <= 2),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kirim_id, attempt_no)
);
CREATE UNIQUE INDEX ux_delivery_active_kirim ON public.deliveries(kirim_id)
  WHERE status NOT IN ('CANCELLED','RETURNED','COMPLETED','REFUNDED','PROCUREMENT_FAILED');
CREATE INDEX ix_deliveries_carrier ON public.deliveries(carrier_id, status);
CREATE INDEX ix_deliveries_settle  ON public.deliveries(settlement_due_at) WHERE status = 'DELIVERED';

CREATE TABLE public.delivery_events (
  id                 UUID NOT NULL DEFAULT uuidv7(),
  delivery_id        UUID NOT NULL,
  seq                BIGINT NOT NULL DEFAULT nextval('public.delivery_events_seq'),
  from_status        ref.kirim_status,
  to_status          ref.kirim_status NOT NULL,
  event              TEXT NOT NULL,
  actor_id           UUID,
  actor_role         ref.user_role,
  source             TEXT NOT NULL CHECK (source IN ('app','admin','system','webhook')),
  client_captured_at TIMESTAMPTZ,
  server_received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  clock_skew_seconds INT,
  geog               GEOGRAPHY(POINT,4326),
  geo_accuracy_m     INT,
  is_mock_location   BOOLEAN,
  is_offline_capture BOOLEAN NOT NULL DEFAULT false,
  idempotency_key    TEXT,
  admin_reason       TEXT,
  metadata           JSONB NOT NULL DEFAULT '{}',
  PRIMARY KEY (id, server_received_at),
  CHECK (source <> 'admin' OR admin_reason IS NOT NULL)
) PARTITION BY RANGE (server_received_at);

CREATE UNIQUE INDEX ux_delivery_events_idem
  ON public.delivery_events(idempotency_key, server_received_at)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX ix_delivery_events_delivery ON public.delivery_events(delivery_id, seq);

CREATE TABLE ref.delivery_transition_rules (
  from_status      ref.kirim_status NOT NULL,
  event            TEXT NOT NULL,
  to_status        ref.kirim_status NOT NULL,
  allowed_roles    ref.user_role[] NOT NULL,
  applies_to_types ref.kirim_type[] NOT NULL DEFAULT '{BELI,HANTAR,PASARAN}',
  requires_proof   BOOLEAN NOT NULL DEFAULT false,
  proof_leg        ref.handover_leg,
  guard_function   TEXT,
  PRIMARY KEY (from_status, event)
);

CREATE TABLE public.handover_codes (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id  UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE RESTRICT,
  leg          ref.handover_leg NOT NULL,
  code_hash    TEXT NOT NULL,
  qr_nonce     TEXT NOT NULL,
  attempts     INT NOT NULL DEFAULT 0,
  max_attempts INT NOT NULL DEFAULT 5,
  locked_at    TIMESTAMPTZ,
  consumed_at  TIMESTAMPTZ,
  rotated_from UUID REFERENCES public.handover_codes(id),
  expires_at   TIMESTAMPTZ NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_handover_active ON public.handover_codes(delivery_id, leg)
  WHERE consumed_at IS NULL AND locked_at IS NULL;

CREATE TABLE internal.handover_nonces (
  nonce       TEXT PRIMARY KEY,
  delivery_id UUID NOT NULL,
  leg         ref.handover_leg NOT NULL,
  consumed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  consumed_by UUID NOT NULL
);

CREATE TABLE public.proofs (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id        UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE RESTRICT,
  leg                ref.handover_leg NOT NULL,
  method             ref.proof_method NOT NULL,
  quality            ref.proof_quality NOT NULL,
  photo_path         TEXT,
  signature_path     TEXT,
  geog               GEOGRAPHY(POINT,4326),
  geo_accuracy_m     INT,
  distance_to_node_m INT,
  captured_at        TIMESTAMPTZ NOT NULL,
  verified_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  verified_by        UUID REFERENCES public.profiles(id),
  is_offline_capture BOOLEAN NOT NULL DEFAULT false,
  flags              TEXT[] NOT NULL DEFAULT '{}',
  CHECK (method <> 'PHOTO' OR photo_path IS NOT NULL)
);
CREATE UNIQUE INDEX ux_proof_per_leg ON public.proofs(delivery_id, leg);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 8 — money (internal)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE internal.ledger_accounts (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  account_code  TEXT NOT NULL UNIQUE,
  account_class ref.account_class NOT NULL,
  owner_type    TEXT CHECK (owner_type IN ('user','carrier','seller','agent','system')),
  owner_id      UUID,
  currency      TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
  is_system     BOOLEAN NOT NULL DEFAULT false,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE internal.ledger_transactions (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  kind            TEXT NOT NULL,
  reference_type  TEXT NOT NULL,
  reference_id    UUID NOT NULL,
  idempotency_key TEXT NOT NULL UNIQUE,
  description     TEXT,
  posted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by      UUID,
  reverses_id     UUID REFERENCES internal.ledger_transactions(id)
);

CREATE TABLE internal.ledger_entries (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  transaction_id UUID NOT NULL REFERENCES internal.ledger_transactions(id),
  account_id     UUID NOT NULL REFERENCES internal.ledger_accounts(id),
  direction      ref.ledger_direction NOT NULL,
  amount_sen     BIGINT NOT NULL CHECK (amount_sen > 0),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_ledger_entries_account ON internal.ledger_entries(account_id, created_at DESC);
CREATE INDEX ix_ledger_entries_txn     ON internal.ledger_entries(transaction_id);

CREATE TABLE internal.bank_accounts (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  owner_id         UUID NOT NULL,
  bank_code        TEXT NOT NULL,
  account_no_enc   BYTEA NOT NULL,
  account_no_last4 TEXT NOT NULL,
  holder_name      TEXT NOT NULL,
  verified_at      TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE internal.payments (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  reference_type    TEXT NOT NULL CHECK (reference_type IN ('kirim','order','topup')),
  reference_id      UUID NOT NULL,
  payer_id          UUID NOT NULL,
  provider          TEXT NOT NULL,
  provider_ref      TEXT,
  method            ref.payment_method NOT NULL,
  amount_sen        BIGINT NOT NULL CHECK (amount_sen > 0),
  status            ref.payment_status NOT NULL DEFAULT 'INITIATED',
  status_precedence INT NOT NULL DEFAULT 0,
  idempotency_key   TEXT NOT NULL UNIQUE,
  failure_code      TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_ref)
);

CREATE TABLE internal.webhook_events (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  provider          TEXT NOT NULL,
  provider_event_id TEXT NOT NULL,
  signature_valid   BOOLEAN NOT NULL,
  payload           JSONB NOT NULL,
  received_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at      TIMESTAMPTZ,
  status            TEXT NOT NULL DEFAULT 'RECEIVED'
                      CHECK (status IN ('RECEIVED','PROCESSED','IGNORED_OUT_OF_ORDER','FAILED')),
  error             TEXT,
  attempts          INT NOT NULL DEFAULT 0,
  CONSTRAINT ux_webhook_idem UNIQUE (provider, provider_event_id)
);

CREATE TABLE internal.payouts (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  payee_type      TEXT NOT NULL CHECK (payee_type IN ('carrier','seller','agent')),
  payee_id        UUID NOT NULL,
  amount_sen      BIGINT NOT NULL CHECK (amount_sen > 0),
  status          ref.payout_status NOT NULL DEFAULT 'REQUESTED',
  bank_account_id UUID NOT NULL REFERENCES internal.bank_accounts(id),
  batch_id        UUID,
  reviewed_by     UUID,
  approved_by     UUID,
  provider_ref    TEXT,
  failure_reason  TEXT,
  requested_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  paid_at         TIMESTAMPTZ,
  CONSTRAINT ck_payout_segregation
    CHECK (approved_by IS NULL OR reviewed_by IS NULL OR approved_by <> reviewed_by)
);

CREATE TABLE internal.cod_collections (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id   UUID NOT NULL UNIQUE REFERENCES public.deliveries(id),
  carrier_id    UUID NOT NULL,
  amount_sen    BIGINT NOT NULL CHECK (amount_sen > 0),
  collected_at  TIMESTAMPTZ NOT NULL,
  remittance_id UUID,
  remitted_at   TIMESTAMPTZ
);

CREATE TABLE internal.idempotency_keys (
  key           TEXT PRIMARY KEY,
  actor_id      UUID NOT NULL,
  endpoint      TEXT NOT NULL,
  request_hash  TEXT NOT NULL,
  response_body JSONB,
  status_code   INT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours'
);

CREATE TABLE internal.job_runs (
  id         UUID PRIMARY KEY DEFAULT uuidv7(),
  job_name   TEXT NOT NULL,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at   TIMESTAMPTZ,
  outcome    TEXT,
  detail     JSONB
);

-- ════════════════════════════════════════════════════════════════════════════
-- LAYER 9 — trust, comms, badges, audit
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE ref.badge_definitions (
  id         UUID PRIMARY KEY DEFAULT uuidv7(),
  slug       TEXT NOT NULL UNIQUE,
  name_ms    TEXT NOT NULL,
  name_en    TEXT NOT NULL,
  icon       TEXT NOT NULL,
  rule       JSONB NOT NULL,
  sort_order INT NOT NULL DEFAULT 0
);

CREATE TABLE public.user_badges (
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  badge_id   UUID NOT NULL REFERENCES ref.badge_definitions(id),
  awarded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, badge_id)
);

CREATE TABLE public.reviews (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id    UUID NOT NULL REFERENCES public.deliveries(id),
  rater_id       UUID NOT NULL REFERENCES public.profiles(id),
  ratee_id       UUID NOT NULL REFERENCES public.profiles(id),
  rating         INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment        TEXT CHECK (length(comment) <= 1000),
  is_visible     BOOLEAN NOT NULL DEFAULT false,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  editable_until TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours',
  CONSTRAINT ck_no_self_review CHECK (rater_id <> ratee_id),
  UNIQUE (delivery_id, rater_id)
);

CREATE TABLE public.disputes (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id     UUID REFERENCES public.deliveries(id),
  order_id        UUID REFERENCES public.orders(id),
  raised_by       UUID NOT NULL REFERENCES public.profiles(id),
  against_id      UUID REFERENCES public.profiles(id),
  category        TEXT NOT NULL CHECK (category IN
                    ('non_delivery','damaged','wrong_item','not_as_described',
                     'payment','overcharge','conduct','other')),
  status          ref.dispute_status NOT NULL DEFAULT 'OPEN',
  description     TEXT NOT NULL,
  holds_escrow    BOOLEAN NOT NULL DEFAULT true,
  resolution_note TEXT,
  refund_sen      BIGINT NOT NULL DEFAULT 0,
  sla_due_at      TIMESTAMPTZ NOT NULL,
  resolved_by     UUID,
  resolved_at     TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (delivery_id IS NOT NULL OR order_id IS NOT NULL)
);

CREATE TABLE public.conversations (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  context_type TEXT NOT NULL CHECK (context_type IN ('kirim','order','dispute')),
  context_id   UUID NOT NULL,
  closed_at    TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (context_type, context_id)
);

CREATE TABLE public.conversation_participants (
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  user_id         UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  last_read_at    TIMESTAMPTZ,
  PRIMARY KEY (conversation_id, user_id)
);

CREATE TABLE public.messages (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  conversation_id UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  sender_id       UUID NOT NULL REFERENCES public.profiles(id),
  body            TEXT CHECK (length(body) <= 2000),
  attachment_path TEXT,
  client_msg_id   TEXT NOT NULL,
  flagged         BOOLEAN NOT NULL DEFAULT false,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, client_msg_id)
);
CREATE INDEX ix_messages_conv ON public.messages(conversation_id, created_at DESC);

CREATE TABLE public.notifications (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  channel     TEXT NOT NULL,
  title_ms    TEXT NOT NULL, title_en TEXT,
  body_ms     TEXT NOT NULL, body_en  TEXT,
  deep_link   TEXT,
  is_critical BOOLEAN NOT NULL DEFAULT false,
  read_at     TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_notifications_unread ON public.notifications(user_id, created_at DESC)
  WHERE read_at IS NULL;

CREATE TABLE internal.notification_outbox (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  notification_id UUID NOT NULL REFERENCES public.notifications(id),
  transport       TEXT NOT NULL CHECK (transport IN ('push','sms','whatsapp')),
  status          TEXT NOT NULL DEFAULT 'PENDING',
  attempts        INT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  receipt_id      TEXT,
  error           TEXT
);

CREATE TABLE internal.risk_signals (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  subject_type TEXT NOT NULL,
  subject_id   UUID NOT NULL,
  signal       TEXT NOT NULL,
  severity     INT NOT NULL CHECK (severity BETWEEN 1 AND 5),
  details      JSONB NOT NULL DEFAULT '{}',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit.audit_logs (
  id          UUID NOT NULL DEFAULT uuidv7(),
  actor_id    UUID,
  actor_role  ref.user_role,
  action      TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id   UUID,
  before      JSONB,
  after       JSONB,
  reason      TEXT,
  ip_address  INET,
  user_agent  TEXT,
  request_id  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- ── Initial partitions (pg_cron creates 3 months ahead thereafter) ──────────
DO $$
DECLARE m DATE := date_trunc('month', now())::date;
BEGIN
  FOR i IN 0..3 LOOP
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS public.delivery_events_%s PARTITION OF public.delivery_events
         FOR VALUES FROM (%L) TO (%L)',
      to_char(m + (i||' month')::interval,'YYYYMM'),
      m + (i||' month')::interval, m + ((i+1)||' month')::interval);
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS audit.audit_logs_%s PARTITION OF audit.audit_logs
         FOR VALUES FROM (%L) TO (%L)',
      to_char(m + (i||' month')::interval,'YYYYMM'),
      m + (i||' month')::interval, m + ((i+1)||' month')::interval);
  END LOOP;
END $$;

-- ── Immutability grants ─────────────────────────────────────────────────────
REVOKE ALL ON ALL TABLES IN SCHEMA internal FROM anon, authenticated;
REVOKE ALL ON ALL TABLES IN SCHEMA audit    FROM anon, authenticated;
REVOKE UPDATE, DELETE ON internal.ledger_entries      FROM PUBLIC;
REVOKE UPDATE, DELETE ON internal.ledger_transactions FROM PUBLIC;
REVOKE UPDATE, DELETE ON audit.audit_logs             FROM PUBLIC;
REVOKE UPDATE, DELETE ON public.delivery_events       FROM authenticated, anon;
REVOKE INSERT, UPDATE, DELETE ON public.deliveries    FROM authenticated, anon;
