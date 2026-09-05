# KasihKirim — Database Design

**PostgreSQL 15+ on Supabase** · PostGIS · pg_cron · pgsodium/Vault

Implements: [`PRD.md`](./PRD.md) · [`ARCHITECTURE.md`](./ARCHITECTURE.md). Policy detail lives in [`SECURITY.md`](./SECURITY.md).

---

## 1. Conventions

These are absolute. A migration that violates one is rejected in review.

| Rule | Detail |
|---|---|
| **Primary keys** | `UUID` v7 (`uuidv7()`), time-ordered for index locality. Never serial, never exposed sequences. |
| **Money** | `BIGINT`, suffix `_sen`. 1 MYR = 100 sen. **No `NUMERIC`, no `FLOAT`, no `MONEY`.** |
| **Rates** | `INT`, suffix `_bps` (basis points). 25 % = `2500`. |
| **Weight** | `INT`, suffix `_grams`. |
| **Volume** | `INT`, suffix `_cm3`. |
| **Distance** | `NUMERIC(8,2)`, suffix `_km` — reference data only, never in a money calculation without conversion to sen first. |
| **Time** | `TIMESTAMPTZ`, always UTC. Never `TIMESTAMP`. Display conversion to Asia/Kuching is a client concern. |
| **Naming** | `snake_case`; tables plural; join tables `a_b`; booleans `is_`/`has_`; indexes `ix_`, unique `ux_`, FK `fk_`, check `ck_`. |
| **Soft delete** | `deleted_at TIMESTAMPTZ` on synced tables. Financial tables are **never** deleted, soft or hard. |
| **Audit columns** | `created_at`, `updated_at` (trigger-maintained) on every table; `created_by` where an actor exists. |
| **Sync columns** | Every client-synced table has `updated_at` with an index — required by the delta-pull endpoint. |
| **Enums** | Native `ENUM` types in `ref`. Values may be added, never removed (deprecate instead). |
| **Text** | `TEXT` with `CHECK (length(...))`. Never `VARCHAR(n)`. |
| **JSONB** | Only for genuinely open-ended structures (rule params, payload snapshots, metadata). Never as a substitute for columns. |

---

## 2. Schemas

Schema separation is the first line of the security model. PostgREST exposes **only `public`**.

| Schema | Exposed to PostgREST | Contents |
|---|---|---|
| `public` | ✅ Yes, RLS-enforced | User-facing entities: profiles, kirim, trips, orders, products, chat, reviews |
| `internal` | ❌ **Never** | Ledger, payments, payouts, commissions, webhooks, idempotency, state-machine functions, job runs |
| `audit` | ❌ Never | Audit logs, admin actions, access logs |
| `ref` | ⚠️ Read-only via views | Enums, transition rules, categories, route graph, pricing rules |

```sql
CREATE SCHEMA internal;  REVOKE ALL ON SCHEMA internal FROM anon, authenticated;
CREATE SCHEMA audit;     REVOKE ALL ON SCHEMA audit    FROM anon, authenticated;
CREATE SCHEMA ref;       GRANT USAGE ON SCHEMA ref TO authenticated;

-- Belt and braces: PostgREST only sees what it is told to see.
-- supabase/config.toml → [api] schemas = ["public", "graphql_public"]
```

**Why this matters more than RLS alone.** A mistaken `GRANT` or a forgotten policy on a table in `public` is a data breach. The same mistake on a table in `internal` is inert, because the API layer cannot address the schema at all. The ledger is therefore unreachable by any client JWT regardless of policy errors.

### 2.1 Extensions

```sql
CREATE EXTENSION IF NOT EXISTS postgis;        -- geography, nearest-node, detour
CREATE EXTENSION IF NOT EXISTS pg_cron;        -- scheduled jobs
CREATE EXTENSION IF NOT EXISTS pgcrypto;       -- HMAC, random
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS btree_gist;     -- exclusion constraints
CREATE EXTENSION IF NOT EXISTS pg_trgm;        -- product/place fuzzy search
-- supabase_vault is provided by the platform (Ed25519 QR key, OTP pepper)
```

---

## 3. Enumerated types

```sql
CREATE TYPE ref.user_role AS ENUM (
  'customer','seller','carrier','agent',
  'admin_support','admin_ops','admin_finance','admin_compliance','admin_super');

CREATE TYPE ref.account_status AS ENUM ('pending','active','suspended','banned','deleted');

CREATE TYPE ref.kirim_type AS ENUM ('BELI','HANTAR','PASARAN');

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

CREATE TYPE ref.account_class AS ENUM ('ASSET','LIABILITY','REVENUE','EXPENSE','EQUITY');

CREATE TYPE ref.verification_status AS ENUM (
  'NOT_STARTED','SUBMITTED','UNDER_REVIEW','MORE_INFO_REQUIRED',
  'APPROVED','REJECTED','SUSPENDED','REVOKED');

CREATE TYPE ref.handover_leg AS ENUM ('pickup','dropoff');

CREATE TYPE ref.proof_method AS ENUM ('QR','OTP','AGENT','PHOTO','ADMIN_OVERRIDE');

CREATE TYPE ref.proof_quality AS ENUM ('STRONG','WEAK','SUSPECT');

CREATE TYPE ref.vehicle_type AS ENUM (
  'MOTORCYCLE','CAR','PICKUP','FOURWD','VAN','LORRY','BOAT');

CREATE TYPE ref.handling_flag AS ENUM (
  'FRAGILE','PERISHABLE','COLD_CHAIN','LIQUID','OVERSIZED','LIVE_ANIMAL','DOCUMENTS','HALAL_SEPARATE');

CREATE TYPE ref.dispute_status AS ENUM (
  'OPEN','UNDER_REVIEW','AWAITING_EVIDENCE','DECIDED',
  'RESOLVED_REFUND_FULL','RESOLVED_REFUND_PARTIAL','RESOLVED_REJECTED','RESOLVED_SPLIT','CLOSED');

CREATE TYPE ref.variance_status AS ENUM ('PENDING','APPROVED','REDUCED','DECLINED','TIMED_OUT');
```

---

## 4. Identity and profile

### 4.1 `public.profiles`

Mirrors `auth.users`. The application never reads `auth.users` directly.

```sql
CREATE TABLE public.profiles (
  id                  UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  phone               TEXT NOT NULL UNIQUE
                        CHECK (phone ~ '^\+60[0-9]{8,10}$'),
  full_name           TEXT CHECK (length(full_name) BETWEEN 2 AND 120),
  display_name        TEXT CHECK (length(display_name) BETWEEN 2 AND 40),
  avatar_path         TEXT,
  preferred_language  TEXT NOT NULL DEFAULT 'ms' CHECK (preferred_language IN ('ms','en')),
  status              ref.account_status NOT NULL DEFAULT 'pending',
  home_community_id   UUID REFERENCES public.communities(id),
  nric_hash           TEXT,          -- HMAC only. Plaintext NRIC is never stored.
  nric_last4          TEXT CHECK (nric_last4 ~ '^[0-9]{4}$'),
  rating_avg          NUMERIC(3,2) NOT NULL DEFAULT 0 CHECK (rating_avg BETWEEN 0 AND 5),
  rating_count        INT NOT NULL DEFAULT 0,
  kirim_sent_count    INT NOT NULL DEFAULT 0,
  kirim_received_count INT NOT NULL DEFAULT 0,
  suspended_reason    TEXT,
  deletion_requested_at TIMESTAMPTZ,
  anonymised_at       TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ
);
CREATE INDEX ix_profiles_updated  ON public.profiles(updated_at);
CREATE INDEX ix_profiles_community ON public.profiles(home_community_id) WHERE deleted_at IS NULL;
```

`ON DELETE RESTRICT` is deliberate: a profile with financial history cannot be removed by deleting the auth user. Deletion goes through the anonymisation path (§16.2).

### 4.2 `public.user_roles`

Roles are normalised for auditability and **mirrored into the JWT** by the custom access token hook, so RLS policies read a claim rather than joining a table.

```sql
CREATE TABLE public.user_roles (
  user_id     UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  role        ref.user_role NOT NULL,
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by  UUID REFERENCES public.profiles(id),
  revoked_at  TIMESTAMPTZ,
  PRIMARY KEY (user_id, role)
);
CREATE INDEX ix_user_roles_active ON public.user_roles(user_id) WHERE revoked_at IS NULL;
```

### 4.3 `public.devices`

```sql
CREATE TABLE public.devices (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id          UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  install_id       TEXT NOT NULL,               -- app-generated, stable per install
  expo_push_token  TEXT,
  model            TEXT,
  os_version       TEXT,
  app_version      TEXT,
  total_ram_mb     INT,                         -- drives server-side payload tuning
  locale           TEXT,
  is_active        BOOLEAN NOT NULL DEFAULT true,
  last_seen_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, install_id)
);
CREATE INDEX ix_devices_push ON public.devices(expo_push_token) WHERE is_active;
```

`total_ram_mb` is not decoration. It lets the server return smaller page sizes and fewer image variants to a 2 GB device — a server-side lever that needs no app update.

### 4.4 `public.addresses`

Rural addressing: community + landmark is the primary key to a location, not street and postcode.

```sql
CREATE TABLE public.addresses (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id          UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  label            TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 40),
  recipient_name   TEXT NOT NULL,
  recipient_phone  TEXT NOT NULL CHECK (recipient_phone ~ '^\+60[0-9]{8,10}$'),
  community_id     UUID NOT NULL REFERENCES public.communities(id),
  landmark_note    TEXT NOT NULL CHECK (length(landmark_note) BETWEEN 3 AND 500),
  photo_path       TEXT,                       -- the real navigation aid
  voice_note_path  TEXT,
  line1            TEXT,                       -- optional by design
  postcode         TEXT CHECK (postcode IS NULL OR postcode ~ '^[0-9]{5}$'),
  district         TEXT,
  state            TEXT NOT NULL DEFAULT 'Sabah',
  geog             GEOGRAPHY(POINT,4326),
  geo_accuracy_m   INT,
  geo_captured_at  TIMESTAMPTZ,
  nearest_node_id  UUID REFERENCES ref.route_nodes(id),   -- resolved server-side
  agent_hub_id     UUID REFERENCES public.agents(id),     -- deliver to hub instead
  delivery_notes   TEXT,
  is_default       BOOLEAN NOT NULL DEFAULT false,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at       TIMESTAMPTZ
);
CREATE UNIQUE INDEX ux_addresses_one_default
  ON public.addresses(user_id) WHERE is_default AND deleted_at IS NULL;
CREATE INDEX ix_addresses_geog ON public.addresses USING GIST(geog);
CREATE INDEX ix_addresses_node ON public.addresses(nearest_node_id);
```

---

## 5. Geography and the route graph

### 5.1 `public.communities` and membership

```sql
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

-- Deck: the profile shows "2 Komuniti" — membership is many-to-many.
CREATE TABLE public.community_members (
  community_id UUID NOT NULL REFERENCES public.communities(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  is_primary   BOOLEAN NOT NULL DEFAULT false,
  PRIMARY KEY (community_id, user_id)
);
CREATE INDEX ix_community_members_user ON public.community_members(user_id);
```

### 5.2 `ref.route_nodes` and `ref.route_edges`

The curated corridor graph (`ARCHITECTURE.md` §6). Admin-maintained; the source of truth for both matching and pricing distance.

```sql
CREATE TABLE ref.route_nodes (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  name          TEXT NOT NULL,
  node_type     TEXT NOT NULL CHECK (node_type IN ('bandar','pekan','junction','kampung','jetty','hub')),
  district      TEXT NOT NULL,
  geog          GEOGRAPHY(POINT,4326) NOT NULL,
  is_major      BOOLEAN NOT NULL DEFAULT false,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_route_nodes_geog ON ref.route_nodes USING GIST(geog);

CREATE TABLE ref.route_edges (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  from_node_id      UUID NOT NULL REFERENCES ref.route_nodes(id),
  to_node_id        UUID NOT NULL REFERENCES ref.route_nodes(id),
  distance_km       NUMERIC(8,2) NOT NULL CHECK (distance_km > 0),
  typical_minutes   INT NOT NULL CHECK (typical_minutes > 0),
  road_quality      TEXT NOT NULL CHECK (road_quality IN ('sealed','gravel','logging','river','sea')),
  min_vehicle_type  ref.vehicle_type NOT NULL DEFAULT 'CAR',
  is_seasonal       BOOLEAN NOT NULL DEFAULT false,
  seasonal_note     TEXT,                        -- e.g. flooding Nov–Feb
  is_active         BOOLEAN NOT NULL DEFAULT true,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_node_id <> to_node_id),
  UNIQUE (from_node_id, to_node_id)
);

-- Precomputed all-pairs distances. Small graph → trivial table, turns
-- quoting into an index lookup instead of a graph traversal.
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
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  name             TEXT NOT NULL,
  boundary         GEOGRAPHY(POLYGON,4326) NOT NULL,
  remoteness_tier  INT NOT NULL CHECK (remoteness_tier BETWEEN 1 AND 5),
  surcharge_bps    INT NOT NULL DEFAULT 0 CHECK (surcharge_bps BETWEEN 0 AND 10000),
  is_serviceable   BOOLEAN NOT NULL DEFAULT true
);
CREATE INDEX ix_zones_boundary ON ref.zones USING GIST(boundary);
```

---

## 6. Carriers, vehicles and trips

### 6.1 `public.carriers`

```sql
CREATE TABLE public.carriers (
  id                      UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id                 UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE RESTRICT,
  status                  ref.verification_status NOT NULL DEFAULT 'NOT_STARTED',
  tier                    INT NOT NULL DEFAULT 1 CHECK (tier BETWEEN 1 AND 4),
  home_community_id       UUID REFERENCES public.communities(id),
  max_detour_km           NUMERIC(5,2) NOT NULL DEFAULT 10,
  -- Exposure controls (BR-908). Both COD cash and BELI purchase advances
  -- draw on the SAME limit, because both are money the carrier is holding.
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
  CONSTRAINT ck_carrier_exposure
    CHECK (cod_held_sen + procurement_advance_sen <= float_limit_sen)
);
```

`ck_carrier_exposure` is the structural enforcement of BR-908 and FR-158. Even if the acceptance logic is wrong, the transaction that would push a carrier over their float aborts.

### 6.2 `public.vehicles`

```sql
CREATE TABLE public.vehicles (
  id                     UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id             UUID NOT NULL REFERENCES public.carriers(id) ON DELETE CASCADE,
  vehicle_type           ref.vehicle_type NOT NULL,
  plate_no               TEXT,                       -- NULL permitted for boats
  make_model             TEXT,
  capacity_weight_grams  INT NOT NULL CHECK (capacity_weight_grams > 0),
  capacity_volume_cm3    INT NOT NULL CHECK (capacity_volume_cm3 > 0),
  capacity_parcels       INT NOT NULL CHECK (capacity_parcels > 0),
  handling_capabilities  ref.handling_flag[] NOT NULL DEFAULT '{}',
  photo_paths            TEXT[] NOT NULL DEFAULT '{}',
  insurance_expiry       DATE,
  road_tax_expiry        DATE,
  is_verified            BOOLEAN NOT NULL DEFAULT false,
  is_active              BOOLEAN NOT NULL DEFAULT true,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 6.3 `public.trips` — capacity and the overbooking guard

```sql
CREATE TABLE public.trips (
  id                     UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id             UUID NOT NULL REFERENCES public.carriers(id) ON DELETE RESTRICT,
  vehicle_id             UUID NOT NULL REFERENCES public.vehicles(id),
  status                 ref.trip_status NOT NULL DEFAULT 'DRAFT',
  origin_node_id         UUID NOT NULL REFERENCES ref.route_nodes(id),
  dest_node_id           UUID NOT NULL REFERENCES ref.route_nodes(id),
  corridor_nodes         UUID[] NOT NULL,           -- ordered path incl. endpoints
  depart_at              TIMESTAMPTZ NOT NULL,
  depart_window_minutes  INT NOT NULL DEFAULT 120,
  arrive_est_at          TIMESTAMPTZ,

  capacity_weight_grams  INT NOT NULL CHECK (capacity_weight_grams > 0),
  capacity_volume_cm3    INT NOT NULL CHECK (capacity_volume_cm3 > 0),
  capacity_parcels       INT NOT NULL CHECK (capacity_parcels > 0),
  reserved_weight_grams  INT NOT NULL DEFAULT 0 CHECK (reserved_weight_grams >= 0),
  reserved_volume_cm3    INT NOT NULL DEFAULT 0 CHECK (reserved_volume_cm3 >= 0),
  reserved_parcels       INT NOT NULL DEFAULT 0 CHECK (reserved_parcels >= 0),

  handling_capabilities  ref.handling_flag[] NOT NULL DEFAULT '{}',
  accepts_cod            BOOLEAN NOT NULL DEFAULT true,
  accepts_beli           BOOLEAN NOT NULL DEFAULT true,   -- willing to buy on request
  is_return_leg          BOOLEAN NOT NULL DEFAULT false,  -- Kirim Balik marker
  parent_trip_id         UUID REFERENCES public.trips(id),
  recurring_rule         TEXT,
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- ═══ THE OVERBOOKING GUARD (BR-903, layer 2) ═══
  CONSTRAINT ck_trip_weight_capacity  CHECK (reserved_weight_grams <= capacity_weight_grams),
  CONSTRAINT ck_trip_volume_capacity  CHECK (reserved_volume_cm3   <= capacity_volume_cm3),
  CONSTRAINT ck_trip_parcel_capacity  CHECK (reserved_parcels      <= capacity_parcels),
  CONSTRAINT ck_trip_distinct_ends    CHECK (origin_node_id <> dest_node_id)
);

CREATE INDEX ix_trips_matching ON public.trips (status, depart_at)
  INCLUDE (reserved_weight_grams, capacity_weight_grams)
  WHERE status IN ('ANNOUNCED','BOARDING');
CREATE INDEX ix_trips_corridor ON public.trips USING GIN(corridor_nodes);
CREATE INDEX ix_trips_carrier  ON public.trips(carrier_id, depart_at DESC);
```

### 6.4 `public.trip_reservations`

```sql
CREATE TABLE public.trip_reservations (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  trip_id         UUID NOT NULL REFERENCES public.trips(id) ON DELETE RESTRICT,
  kirim_id        UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  status          ref.reservation_status NOT NULL DEFAULT 'HELD',
  weight_grams    INT NOT NULL CHECK (weight_grams > 0),
  volume_cm3      INT NOT NULL CHECK (volume_cm3 > 0),
  parcels         INT NOT NULL DEFAULT 1 CHECK (parcels > 0),
  stop_sequence   INT,
  expires_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  released_at     TIMESTAMPTZ,
  CHECK (status <> 'HELD' OR expires_at IS NOT NULL)
);
-- One live reservation per kirim, ever.
CREATE UNIQUE INDEX ux_reservation_active_kirim
  ON public.trip_reservations(kirim_id) WHERE status IN ('HELD','CONFIRMED');
CREATE INDEX ix_reservation_expiry
  ON public.trip_reservations(expires_at) WHERE status = 'HELD';
```

### 6.5 Capacity trigger (layer 2 enforcement)

```sql
CREATE OR REPLACE FUNCTION internal.tg_sync_trip_reserved()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_trip UUID := COALESCE(NEW.trip_id, OLD.trip_id);
BEGIN
  UPDATE public.trips t SET
    reserved_weight_grams = COALESCE(a.w,0),
    reserved_volume_cm3   = COALESCE(a.v,0),
    reserved_parcels      = COALESCE(a.p,0),
    updated_at            = now()
  FROM (
    SELECT sum(weight_grams) w, sum(volume_cm3) v, sum(parcels) p
    FROM public.trip_reservations
    WHERE trip_id = v_trip AND status IN ('HELD','CONFIRMED','CONSUMED')
  ) a
  WHERE t.id = v_trip;
  RETURN NULL;   -- AFTER trigger
END $$;

CREATE CONSTRAINT TRIGGER tg_trip_reserved_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.trip_reservations
  DEFERRABLE INITIALLY IMMEDIATE
  FOR EACH ROW EXECUTE FUNCTION internal.tg_sync_trip_reserved();
```

The `UPDATE` fires the `CHECK` constraints on `trips`. Any reservation that would exceed capacity raises and rolls back the whole transaction.

---

## 7. Kirim — the demand entity

### 7.1 `public.kirim_requests`

```sql
CREATE TABLE public.kirim_requests (
  id                  UUID PRIMARY KEY DEFAULT uuidv7(),
  reference_code      TEXT NOT NULL UNIQUE,          -- human-readable e.g. KK-7F3K2A
  requester_id        UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  kirim_type          ref.kirim_type NOT NULL,
  status              ref.kirim_status NOT NULL DEFAULT 'DRAFT',

  -- What (deck step 1: "Apa yang awak nak?")
  item_description    TEXT NOT NULL CHECK (length(item_description) BETWEEN 3 AND 500),
  category_id         UUID NOT NULL REFERENCES ref.categories(id),
  est_weight_grams    INT NOT NULL CHECK (est_weight_grams BETWEEN 100 AND 500000),
  actual_weight_grams INT,
  volume_cm3          INT NOT NULL DEFAULT 8000,
  handling_flags      ref.handling_flag[] NOT NULL DEFAULT '{}',
  photo_paths         TEXT[] NOT NULL DEFAULT '{}',
  declared_value_sen  BIGINT CHECK (declared_value_sen >= 0),

  -- BELI only: the budget cap (deck: "Had Bajet", max RM250)
  budget_cap_sen      BIGINT CHECK (budget_cap_sen > 0),
  actual_goods_sen    BIGINT CHECK (actual_goods_sen >= 0),
  goods_receipt_path  TEXT,
  goods_purchased_at  TIMESTAMPTZ,

  -- Where
  origin_address_id   UUID REFERENCES public.addresses(id),
  dest_address_id     UUID NOT NULL REFERENCES public.addresses(id),
  origin_node_id      UUID NOT NULL REFERENCES ref.route_nodes(id),
  dest_node_id        UUID NOT NULL REFERENCES ref.route_nodes(id),

  -- When
  pickup_date         DATE,
  pickup_window       TEXT CHECK (pickup_window IN ('pagi','tengahari','petang','malam')),
  deliver_by_date     DATE,

  -- Money (all server-written)
  quote_id            UUID REFERENCES internal.quotes(id),
  delivery_fee_sen    BIGINT CHECK (delivery_fee_sen >= 0),
  commission_sen      BIGINT CHECK (commission_sen >= 0),
  total_escrow_sen    BIGINT CHECK (total_escrow_sen >= 0),
  payment_method      ref.payment_method,
  voucher_id          UUID REFERENCES public.voucher_issuances(id),
  discount_sen        BIGINT NOT NULL DEFAULT 0 CHECK (discount_sen >= 0),

  -- Links
  order_id            UUID REFERENCES public.orders(id),
  visibility          TEXT NOT NULL DEFAULT 'board' CHECK (visibility IN ('board','direct')),
  expires_at          TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at          TIMESTAMPTZ,

  -- ═══ Type invariants ═══
  CONSTRAINT ck_beli_has_budget
    CHECK (kirim_type <> 'BELI' OR budget_cap_sen IS NOT NULL),
  CONSTRAINT ck_beli_budget_ceiling
    CHECK (budget_cap_sen IS NULL OR budget_cap_sen <= 25000),        -- RM250 (C-03)
  CONSTRAINT ck_hantar_has_origin
    CHECK (kirim_type <> 'HANTAR' OR origin_address_id IS NOT NULL),
  CONSTRAINT ck_pasaran_has_order
    CHECK (kirim_type <> 'PASARAN' OR order_id IS NOT NULL),
  CONSTRAINT ck_distinct_nodes
    CHECK (origin_node_id <> dest_node_id)
);

CREATE INDEX ix_kirim_board ON public.kirim_requests (status, created_at DESC)
  WHERE status = 'POSTED' AND deleted_at IS NULL;
CREATE INDEX ix_kirim_nodes     ON public.kirim_requests(origin_node_id, dest_node_id)
  WHERE status = 'POSTED';
CREATE INDEX ix_kirim_requester ON public.kirim_requests(requester_id, created_at DESC);
CREATE INDEX ix_kirim_updated   ON public.kirim_requests(updated_at);
CREATE INDEX ix_kirim_expiry    ON public.kirim_requests(expires_at) WHERE status = 'POSTED';
```

**The budget-cap invariant (BR-913)** cannot be a simple `CHECK` because a legitimate overspend requires an approved variance. It is enforced by trigger:

```sql
CREATE OR REPLACE FUNCTION internal.tg_enforce_budget_cap()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.kirim_type = 'BELI' AND NEW.actual_goods_sen IS NOT NULL
     AND NEW.actual_goods_sen > NEW.budget_cap_sen THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.price_variances v
      WHERE v.kirim_id = NEW.id
        AND v.status = 'APPROVED'
        AND v.approved_amount_sen >= NEW.actual_goods_sen
    ) THEN
      RAISE EXCEPTION
        'BR-913: actual goods cost %s exceeds budget cap %s without an approved variance',
        NEW.actual_goods_sen, NEW.budget_cap_sen
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER tg_kirim_budget_cap
  BEFORE INSERT OR UPDATE OF actual_goods_sen ON public.kirim_requests
  FOR EACH ROW EXECUTE FUNCTION internal.tg_enforce_budget_cap();
```

### 7.2 `public.price_variances`

The mechanism behind the deck's promise *"Kalau harga pasar lebih tinggi, kita akan hubungi awak."*

```sql
CREATE TABLE public.price_variances (
  id                   UUID PRIMARY KEY DEFAULT uuidv7(),
  kirim_id             UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  raised_by            UUID NOT NULL REFERENCES public.profiles(id),
  status               ref.variance_status NOT NULL DEFAULT 'PENDING',
  original_cap_sen     BIGINT NOT NULL,
  market_price_sen     BIGINT NOT NULL CHECK (market_price_sen > 0),
  requested_amount_sen BIGINT NOT NULL,
  approved_amount_sen  BIGINT,
  evidence_photo_path  TEXT NOT NULL,             -- price tag / receipt, mandatory
  carrier_note         TEXT,
  requester_note       TEXT,
  responded_by         UUID REFERENCES public.profiles(id),
  responded_at         TIMESTAMPTZ,
  expires_at           TIMESTAMPTZ NOT NULL,      -- timeout ⇒ DECLINED (safe default)
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (status <> 'APPROVED' OR approved_amount_sen IS NOT NULL)
);
CREATE UNIQUE INDEX ux_variance_one_pending
  ON public.price_variances(kirim_id) WHERE status = 'PENDING';
CREATE INDEX ix_variance_expiry ON public.price_variances(expires_at) WHERE status = 'PENDING';
```

### 7.3 `public.deliveries`

The execution record. Separated from `kirim_requests` so a re-match after a carrier cancellation produces a new delivery attempt without corrupting the request's history.

```sql
CREATE TABLE public.deliveries (
  id                    UUID PRIMARY KEY DEFAULT uuidv7(),
  kirim_id              UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  trip_id               UUID REFERENCES public.trips(id),
  carrier_id            UUID NOT NULL REFERENCES public.carriers(id),
  reservation_id        UUID REFERENCES public.trip_reservations(id),
  attempt_no            INT NOT NULL DEFAULT 1,
  status                ref.kirim_status NOT NULL DEFAULT 'MATCHED',

  cod_amount_sen        BIGINT NOT NULL DEFAULT 0 CHECK (cod_amount_sen >= 0),
  carrier_earning_sen   BIGINT CHECK (carrier_earning_sen >= 0),
  agent_fee_sen         BIGINT NOT NULL DEFAULT 0,
  platform_fee_sen      BIGINT CHECK (platform_fee_sen >= 0),

  matched_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  picked_up_at          TIMESTAMPTZ,
  delivered_at          TIMESTAMPTZ,
  recipient_confirmed_at TIMESTAMPTZ,             -- BR-907 primary release trigger
  completed_at          TIMESTAMPTZ,
  settlement_due_at     TIMESTAMPTZ,              -- fallback release

  pickup_proof_quality  ref.proof_quality,
  dropoff_proof_quality ref.proof_quality,
  failure_reason        TEXT,
  retry_count           INT NOT NULL DEFAULT 0 CHECK (retry_count <= 2),

  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kirim_id, attempt_no)
);
CREATE UNIQUE INDEX ux_delivery_active_kirim ON public.deliveries(kirim_id)
  WHERE status NOT IN ('CANCELLED','RETURNED','COMPLETED','REFUNDED','PROCUREMENT_FAILED');
CREATE INDEX ix_deliveries_carrier ON public.deliveries(carrier_id, status);
CREATE INDEX ix_deliveries_settle  ON public.deliveries(settlement_due_at)
  WHERE status = 'DELIVERED';
```

**No client role holds `UPDATE` on this table.** See §14.

### 7.4 `public.delivery_events` — append-only

```sql
CREATE TABLE public.delivery_events (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id        UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE RESTRICT,
  seq                BIGINT GENERATED ALWAYS AS IDENTITY,
  from_status        ref.kirim_status,
  to_status          ref.kirim_status NOT NULL,
  event              TEXT NOT NULL,
  actor_id           UUID REFERENCES public.profiles(id),
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
  CHECK (source <> 'admin' OR admin_reason IS NOT NULL)
) PARTITION BY RANGE (server_received_at);

CREATE UNIQUE INDEX ux_delivery_events_idem
  ON public.delivery_events(idempotency_key) WHERE idempotency_key IS NOT NULL;
CREATE INDEX ix_delivery_events_delivery ON public.delivery_events(delivery_id, seq);
```

`REVOKE UPDATE, DELETE ON public.delivery_events FROM authenticated, service_role;`

The unique index on `idempotency_key` is what makes an offline handover submitted three times produce exactly one transition.

### 7.5 `ref.delivery_transition_rules`

The state machine as data (`ARCHITECTURE.md` §5.1).

```sql
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
```

---

## 8. Handover — QR and OTP

```sql
CREATE TABLE public.handover_codes (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id    UUID NOT NULL REFERENCES public.deliveries(id) ON DELETE RESTRICT,
  leg            ref.handover_leg NOT NULL,
  code_hash      TEXT NOT NULL,          -- HMAC-SHA256(code, vault pepper)
  qr_nonce       TEXT NOT NULL,
  attempts       INT NOT NULL DEFAULT 0,
  max_attempts   INT NOT NULL DEFAULT 5,
  locked_at      TIMESTAMPTZ,
  consumed_at    TIMESTAMPTZ,
  rotated_from   UUID REFERENCES public.handover_codes(id),
  expires_at     TIMESTAMPTZ NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_handover_active
  ON public.handover_codes(delivery_id, leg) WHERE consumed_at IS NULL AND locked_at IS NULL;

-- Single-use enforcement for offline-scanned QR tokens.
CREATE TABLE internal.handover_nonces (
  nonce        TEXT PRIMARY KEY,
  delivery_id  UUID NOT NULL,
  leg          ref.handover_leg NOT NULL,
  consumed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  consumed_by  UUID NOT NULL
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
```

The plaintext OTP is never stored anywhere. `code_hash` is an HMAC keyed by a Vault-held pepper, so a database dump alone does not yield working handover codes.

---

## 9. Marketplace

```sql
CREATE TABLE ref.categories (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  slug        TEXT NOT NULL UNIQUE,
  name_ms     TEXT NOT NULL,
  name_en     TEXT NOT NULL,
  parent_id   UUID REFERENCES ref.categories(id),
  icon        TEXT,
  default_handling ref.handling_flag[] NOT NULL DEFAULT '{}',
  sort_order  INT NOT NULL DEFAULT 0,
  is_active   BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE public.sellers (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id            UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE RESTRICT,
  business_name      TEXT NOT NULL,
  ssm_reg_no         TEXT,                    -- optional; many are unregistered
  community_id       UUID NOT NULL REFERENCES public.communities(id),
  status             ref.verification_status NOT NULL DEFAULT 'NOT_STARTED',
  tier               INT NOT NULL DEFAULT 1,
  commission_bps     INT CHECK (commission_bps BETWEEN 0 AND 10000),  -- NULL ⇒ platform default
  rating_avg         NUMERIC(3,2) NOT NULL DEFAULT 0,
  verified_at        TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  seller_id          UUID NOT NULL REFERENCES public.sellers(id) ON DELETE RESTRICT,
  title              TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
  description        TEXT,
  category_id        UUID NOT NULL REFERENCES ref.categories(id),
  status             TEXT NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft','pending_review','active','paused','rejected','delisted')),
  price_sen          BIGINT NOT NULL CHECK (price_sen > 0),
  unit               TEXT NOT NULL DEFAULT 'kg',
  weight_grams       INT NOT NULL CHECK (weight_grams > 0),
  volume_cm3         INT NOT NULL DEFAULT 8000,
  handling_flags     ref.handling_flag[] NOT NULL DEFAULT '{}',
  min_order_qty      INT NOT NULL DEFAULT 1,
  rejection_reason   TEXT,
  search_vector      TSVECTOR GENERATED ALWAYS AS (
                       to_tsvector('simple', coalesce(title,'') || ' ' || coalesce(description,''))
                     ) STORED,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at         TIMESTAMPTZ
);
CREATE INDEX ix_products_search ON public.products USING GIN(search_vector);
CREATE INDEX ix_products_browse ON public.products(category_id, created_at DESC)
  WHERE status = 'active' AND deleted_at IS NULL;

CREATE TABLE public.product_images (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  product_id  UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  storage_path TEXT NOT NULL,
  sort_order  INT NOT NULL DEFAULT 0,
  width       INT, height INT, bytes INT CHECK (bytes <= 300000),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.inventory (
  product_id    UUID PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  on_hand       INT NOT NULL DEFAULT 0 CHECK (on_hand >= 0),
  reserved      INT NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  safety_stock  INT NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_inventory_not_oversold CHECK (reserved <= on_hand)
);

CREATE TABLE public.inventory_movements (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  product_id  UUID NOT NULL REFERENCES public.products(id),
  delta       INT NOT NULL,
  reason      TEXT NOT NULL,
  reference_id UUID,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by  UUID REFERENCES public.profiles(id)
);

CREATE TABLE public.orders (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  order_group_id    UUID NOT NULL,
  reference_code    TEXT NOT NULL UNIQUE,
  buyer_id          UUID NOT NULL REFERENCES public.profiles(id) ON DELETE RESTRICT,
  seller_id         UUID NOT NULL REFERENCES public.sellers(id) ON DELETE RESTRICT,
  status            ref.order_status NOT NULL DEFAULT 'CREATED',
  goods_subtotal_sen BIGINT NOT NULL CHECK (goods_subtotal_sen >= 0),
  delivery_fee_sen  BIGINT NOT NULL DEFAULT 0,
  discount_sen      BIGINT NOT NULL DEFAULT 0,
  commission_sen    BIGINT NOT NULL DEFAULT 0,
  total_sen         BIGINT NOT NULL CHECK (total_sen >= 0),
  currency          TEXT NOT NULL DEFAULT 'MYR' CHECK (currency = 'MYR'),
  payment_method    ref.payment_method,
  quote_id          UUID REFERENCES internal.quotes(id),
  address_snapshot  JSONB NOT NULL,            -- frozen at checkout
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_order_total
    CHECK (total_sen = goods_subtotal_sen + delivery_fee_sen - discount_sen)
);

CREATE TABLE public.order_items (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  order_id       UUID NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  product_id     UUID NOT NULL REFERENCES public.products(id),
  title_snapshot TEXT NOT NULL,               -- never join to live product for money
  price_sen      BIGINT NOT NULL CHECK (price_sen > 0),
  quantity       INT NOT NULL CHECK (quantity > 0),
  weight_grams   INT NOT NULL,
  line_total_sen BIGINT NOT NULL,
  CONSTRAINT ck_line_total CHECK (line_total_sen = price_sen * quantity)
);
```

Price and title are **snapshotted** into `order_items`. A seller editing a product must never retroactively change what a past order cost.

---

## 10. Money — the `internal` schema

### 10.1 Ledger

```sql
CREATE TABLE internal.ledger_accounts (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  account_code  TEXT NOT NULL UNIQUE,        -- 'CARRIER_PAYABLE:{uuid}' or 'ESCROW_HELD'
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

REVOKE UPDATE, DELETE ON internal.ledger_entries       FROM PUBLIC;
REVOKE UPDATE, DELETE ON internal.ledger_transactions  FROM PUBLIC;
```

**The balance invariant.** A deferred constraint trigger, so a multi-statement posting is checked at commit rather than mid-flight:

```sql
CREATE OR REPLACE FUNCTION internal.tg_assert_balanced()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_diff BIGINT;
BEGIN
  SELECT COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen ELSE -amount_sen END),0)
    INTO v_diff
  FROM internal.ledger_entries WHERE transaction_id = NEW.transaction_id;

  IF v_diff <> 0 THEN
    RAISE EXCEPTION 'Unbalanced ledger transaction %: debits minus credits = % sen',
      NEW.transaction_id, v_diff USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER tg_ledger_balanced
  AFTER INSERT ON internal.ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION internal.tg_assert_balanced();
```

Balances are derived, never stored as an authoritative column:

```sql
CREATE MATERIALIZED VIEW internal.mv_account_balances AS
SELECT a.id AS account_id, a.account_code, a.owner_type, a.owner_id,
       COALESCE(SUM(CASE WHEN e.direction='DEBIT'  THEN e.amount_sen ELSE 0 END),0)
     - COALESCE(SUM(CASE WHEN e.direction='CREDIT' THEN e.amount_sen ELSE 0 END),0)
       AS balance_sen
FROM internal.ledger_accounts a
LEFT JOIN internal.ledger_entries e ON e.account_id = a.id
GROUP BY a.id;
CREATE UNIQUE INDEX ux_mv_balances ON internal.mv_account_balances(account_id);
```

Users see their own balance through a narrow `public` view:

```sql
CREATE VIEW public.v_my_earnings
WITH (security_invoker = false, security_barrier = true) AS
SELECT
  SUM(CASE WHEN d.status='COMPLETED' THEN d.carrier_earning_sen ELSE 0 END) AS available_sen,
  SUM(CASE WHEN d.status IN ('DELIVERED','IN_TRANSIT','PICKED_UP')
           THEN d.carrier_earning_sen ELSE 0 END)                            AS pending_sen
FROM public.deliveries d
JOIN public.carriers c ON c.id = d.carrier_id
WHERE c.user_id = (SELECT auth.uid());
```

### 10.2 Quotes, pricing and commission

```sql
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
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  party          TEXT NOT NULL CHECK (party IN ('platform','agent','carrier')),
  basis          TEXT NOT NULL CHECK (basis IN ('order_total','goods_subtotal','delivery_fee','flat')),
  rate_bps       INT NOT NULL CHECK (rate_bps BETWEEN 0 AND 10000),
  flat_sen       BIGINT NOT NULL DEFAULT 0,
  max_commission_sen BIGINT,        -- optional cap; NULL at launch (see ADR-14)
  min_commission_sen BIGINT NOT NULL DEFAULT 0,
  kirim_type     ref.kirim_type,
  effective_from TIMESTAMPTZ NOT NULL,
  effective_to   TIMESTAMPTZ
);

CREATE TABLE internal.quotes (
  id                  UUID PRIMARY KEY DEFAULT uuidv7(),
  subject_type        TEXT NOT NULL CHECK (subject_type IN ('kirim','order')),
  requester_id        UUID NOT NULL,
  input_snapshot      JSONB NOT NULL,
  breakdown           JSONB NOT NULL,
  goods_budget_sen    BIGINT NOT NULL DEFAULT 0,
  delivery_fee_sen    BIGINT NOT NULL,
  commission_sen      BIGINT NOT NULL,
  discount_sen        BIGINT NOT NULL DEFAULT 0,
  total_sen           BIGINT NOT NULL,
  pricing_rule_version INT NOT NULL REFERENCES internal.pricing_rules(version),
  corridor_km         NUMERIC(8,2),
  expires_at          TIMESTAMPTZ NOT NULL,
  consumed_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

Pinning `pricing_rule_version` on every quote means a price computed in March is still reproducible in September, after three rate changes.

### 10.3 Payments, webhooks, payouts

```sql
CREATE TABLE internal.payments (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  reference_type   TEXT NOT NULL CHECK (reference_type IN ('kirim','order','topup')),
  reference_id     UUID NOT NULL,
  payer_id         UUID NOT NULL,
  provider         TEXT NOT NULL,
  provider_ref     TEXT,
  method           ref.payment_method NOT NULL,
  amount_sen       BIGINT NOT NULL CHECK (amount_sen > 0),
  status           ref.payment_status NOT NULL DEFAULT 'INITIATED',
  status_precedence INT NOT NULL DEFAULT 0,     -- out-of-order webhook guard
  idempotency_key  TEXT NOT NULL UNIQUE,
  failure_code     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
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
```

`ux_webhook_idem` is the entire idempotency guarantee (BR-904 / FR-204). Two concurrent Edge Function instances handed the same event cannot both process it — the second insert conflicts.

```sql
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
  -- Maker/checker separation (BR-909)
  CONSTRAINT ck_payout_segregation
    CHECK (approved_by IS NULL OR reviewed_by IS NULL OR approved_by <> reviewed_by)
);

CREATE TABLE internal.bank_accounts (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  owner_id          UUID NOT NULL,
  bank_code         TEXT NOT NULL,
  account_no_enc    BYTEA NOT NULL,          -- pgsodium/Vault encrypted
  account_no_last4  TEXT NOT NULL,
  holder_name       TEXT NOT NULL,
  verified_at       TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
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
```

---

## 11. Vouchers and badges

The deck commits to a 12-month voucher programme funded from the raise, so burn must be measurable and capped.

```sql
CREATE TABLE public.voucher_campaigns (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  code_prefix        TEXT NOT NULL,
  name               TEXT NOT NULL,
  discount_type      TEXT NOT NULL CHECK (discount_type IN ('fixed','percent')),
  discount_value     INT NOT NULL CHECK (discount_value > 0),
  max_discount_sen   BIGINT,
  min_order_sen      BIGINT NOT NULL DEFAULT 0,
  applies_to         ref.kirim_type[],
  budget_ceiling_sen BIGINT NOT NULL,          -- hard stop against the raise
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
CREATE UNIQUE INDEX ux_voucher_single_use
  ON public.voucher_issuances(id) WHERE redeemed_at IS NOT NULL;

CREATE TABLE ref.badge_definitions (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  slug        TEXT NOT NULL UNIQUE,          -- 'kirim_pertama'
  name_ms     TEXT NOT NULL,
  name_en     TEXT NOT NULL,
  icon        TEXT NOT NULL,
  rule        JSONB NOT NULL,                -- evaluated server-side only
  sort_order  INT NOT NULL DEFAULT 0
);

CREATE TABLE public.user_badges (
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  badge_id   UUID NOT NULL REFERENCES ref.badge_definitions(id),
  awarded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, badge_id)
);
```

`ck_campaign_budget` means voucher spend physically cannot exceed the campaign ceiling. The programme stops itself rather than relying on someone watching a dashboard.

---

## 12. Trust, safety and communication

```sql
CREATE TABLE public.reviews (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  delivery_id  UUID NOT NULL REFERENCES public.deliveries(id),
  rater_id     UUID NOT NULL REFERENCES public.profiles(id),
  ratee_id     UUID NOT NULL REFERENCES public.profiles(id),
  rating       INT NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment      TEXT CHECK (length(comment) <= 1000),
  is_visible   BOOLEAN NOT NULL DEFAULT false,   -- double-blind until reveal
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  editable_until TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '24 hours',
  CONSTRAINT ck_no_self_review CHECK (rater_id <> ratee_id),   -- BR-910
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
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  context_type  TEXT NOT NULL CHECK (context_type IN ('kirim','order','dispute')),
  context_id    UUID NOT NULL,
  closed_at     TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
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
  client_msg_id   TEXT NOT NULL,               -- offline dedupe
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
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  notification_id UUID NOT NULL REFERENCES public.notifications(id),
  transport     TEXT NOT NULL CHECK (transport IN ('push','sms','whatsapp')),
  status        TEXT NOT NULL DEFAULT 'PENDING',
  attempts      INT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  receipt_id    TEXT,
  error         TEXT
);

CREATE TABLE internal.risk_signals (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  subject_type TEXT NOT NULL,
  subject_id  UUID NOT NULL,
  signal      TEXT NOT NULL,
  severity    INT NOT NULL CHECK (severity BETWEEN 1 AND 5),
  details     JSONB NOT NULL DEFAULT '{}',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE audit.audit_logs (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  actor_id     UUID,
  actor_role   ref.user_role,
  action       TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    UUID,
  before       JSONB,
  after        JSONB,
  reason       TEXT,
  ip_address   INET,
  user_agent   TEXT,
  request_id   TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);
REVOKE UPDATE, DELETE ON audit.audit_logs FROM PUBLIC;
```

---

## 13. Core functions

Full signatures and behaviour are specified in [`API.md`](./API.md). Summary:

| Function | Schema | Purpose |
|---|---|---|
| `fn_quote_kirim(...)` | `internal` | Server-only pricing; returns a pinned, expiring quote |
| `fn_reserve_capacity(trip, kirim, w, v, p)` | `internal` | `FOR UPDATE` lock + insert reservation; the only capacity writer |
| `fn_release_capacity(reservation_id, reason)` | `internal` | Releases a hold |
| `fn_delivery_transition(delivery, event, actor, payload)` | `internal` | The **only** writer of `deliveries.status` |
| `fn_verify_handover(delivery, leg, method, token_or_code, geo)` | `internal` | QR signature / OTP hash verification, nonce consumption |
| `fn_post_ledger(kind, ref_type, ref_id, entries[], idem_key)` | `internal` | The only writer of `ledger_entries` |
| `fn_settle_delivery(delivery_id)` | `internal` | Escrow split incl. procurement refund (BR-915) |
| `fn_match_kirim_for_trip(trip_id, limit)` | `internal` | Ranked board results for a carrier |
| `fn_match_trips_for_kirim(kirim_id, limit)` | `internal` | Ranked board results for a requester |
| `fn_resolve_nearest_node(geog)` | `internal` | Address → route node |
| `fn_apply_voucher(user, campaign, subject)` | `internal` | Validates limits and ceiling, computes discount |
| `fn_award_badges(user_id)` | `internal` | Evaluates badge rules |
| `auth.user_roles()` | `auth` | STABLE claim reader used by RLS |

---

## 14. Write-access matrix

The most important table in this document. "—" means **no policy exists**, so the operation is denied.

| Table | `authenticated` SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `profiles` | own + limited public | — (trigger on signup) | own, non-privileged columns | — |
| `addresses` | own | own | own | soft only |
| `kirim_requests` | own + `POSTED` board | own, `DRAFT` only | own, **`DRAFT` only** | — |
| `deliveries` | counterparties | — | **—** | — |
| `delivery_events` | counterparties | — | — | — |
| `trips` | own + `ANNOUNCED` board | own carrier | own, pre-`DEPARTED`, non-capacity columns | — |
| `trip_reservations` | counterparties | — | — | — |
| `handover_codes` | — (never readable) | — | — | — |
| `proofs` | counterparties | — | — | — |
| `price_variances` | counterparties | carrier only | requester response only | — |
| `products` | active + own | own seller | own seller | soft only |
| `inventory` | own seller | — | — | — |
| `orders` | buyer + seller | — | — | — |
| `voucher_issuances` | own | — | — | — |
| `user_badges` | own + public | — | — | — |
| `reviews` | visible + own | own, post-completion | own, within edit window | — |
| `messages` | participants | participants | — | — |
| `internal.*` | **unreachable — schema not exposed** | | | |
| `audit.*` | **unreachable — schema not exposed** | | | |

---

## 15. Indexing and partitioning

### 15.1 Hot-path indexes

Every index below exists to serve a specific query in `API.md`. Indexes without a named consumer are removed — on a small instance, write amplification is a real cost.

| Query | Index |
|---|---|
| Papan Kirim board page | `ix_kirim_board` (partial, `POSTED`) |
| Corridor matching | `ix_kirim_nodes`, `ix_trips_corridor` (GIN) |
| Carrier's active trips | `ix_trips_carrier` |
| Capacity expiry sweep | `ix_reservation_expiry` (partial) |
| Delivery timeline | `ix_delivery_events_delivery` |
| Settlement sweep | `ix_deliveries_settle` (partial) |
| Product browse | `ix_products_browse` (partial) |
| Product search | `ix_products_search` (GIN) |
| Delta sync | `ix_*_updated` on every synced table |
| Unread inbox | `ix_notifications_unread` (partial) |
| Ledger by account | `ix_ledger_entries_account` |

**Every column referenced in an RLS policy must be indexed.** An unindexed policy column turns a policy into a sequential scan on every request.

### 15.2 Partitioning

| Table | Strategy | Retention |
|---|---|---|
| `delivery_events` | Monthly range on `server_received_at` | 24 months hot, then archive |
| `audit.audit_logs` | Monthly range | 7 years (LGL-10) |
| `delivery_tracking_points` | Daily range | **30 days**, then dropped |
| `internal.webhook_events` | Monthly range | 24 months |
| `notifications` | Monthly range | 12 months |

Partitions are created three months ahead by a `pg_cron` job. A missing partition is an outage, so the job alerts on failure rather than logging quietly.

---

## 16. Data lifecycle

### 16.1 Retention

| Class | Retention | Basis |
|---|---|---|
| Financial (ledger, payments, payouts, orders) | **7 years** | Malaysian tax record-keeping |
| KYC documents | 7 years post-relationship | AML/compliance |
| Delivery events and proofs | 24 months | Dispute window + analytics |
| Location tracking points | 30 days | Data minimisation (PDPA) |
| Chat messages | 12 months post-closure | Dispute evidence |
| Notifications | 12 months | Operational |
| Risk signals | 24 months | Fraud pattern detection |

### 16.2 Account deletion (FR-106, LGL-06)

Play policy requires deletion; Malaysian tax law requires retention of financial records. Both are satisfied by **pseudonymisation**, not erasure:

```sql
CREATE OR REPLACE FUNCTION internal.fn_anonymise_user(p_user UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  -- Refuse while money is in flight.
  IF EXISTS (SELECT 1 FROM public.deliveries d
             JOIN public.carriers c ON c.id = d.carrier_id
             WHERE c.user_id = p_user
               AND d.status NOT IN ('COMPLETED','CANCELLED','RETURNED','REFUNDED'))
     OR EXISTS (SELECT 1 FROM internal.payouts
                WHERE payee_id = p_user AND status NOT IN ('PAID','REJECTED','FAILED'))
  THEN
    RAISE EXCEPTION 'Cannot delete: active deliveries or pending payouts exist';
  END IF;

  UPDATE public.profiles SET
    phone         = '+60000000000' || substr(id::text,1,6),
    full_name     = NULL,
    display_name  = 'Pengguna Dipadam',
    avatar_path   = NULL,
    nric_hash     = NULL,
    nric_last4    = NULL,
    status        = 'deleted',
    anonymised_at = now()
  WHERE id = p_user;

  DELETE FROM public.addresses WHERE user_id = p_user;
  DELETE FROM public.devices   WHERE user_id = p_user;
  UPDATE public.messages SET body = '[dipadam]', attachment_path = NULL WHERE sender_id = p_user;

  -- Ledger, payments, payouts, orders: UNTOUCHED. They now reference an
  -- anonymised subject, which satisfies both PDPA and tax retention.
END $$;
```

The user-facing promise must state this honestly: personal details are erased, transaction records are retained for the legally required period.

---

## 17. Seed data

### 17.1 Categories (deck-confirmed)

```sql
INSERT INTO ref.categories (slug, name_ms, name_en, default_handling, sort_order) VALUES
  ('sayur',     'Sayur',      'Vegetables', '{PERISHABLE}',              1),
  ('buah',      'Buah',       'Fruit',      '{PERISHABLE}',              2),
  ('hasil-laut','Hasil Laut', 'Seafood',    '{PERISHABLE,COLD_CHAIN}',   3),
  ('kraf',      'Kraf',       'Handicraft', '{FRAGILE}',                 4),
  ('lain-lain', 'Lain-lain',  'Other',      '{}',                        5);
```

### 17.2 Launch corridor — Beluran ↔ Kota Kinabalu

The deck's flagship route. Roughly 250 km via Telupid; a long-haul rural corridor, which is precisely why the return-leg model works there.

```sql
INSERT INTO ref.route_nodes (name, node_type, district, geog, is_major) VALUES
  ('Kota Kinabalu',      'bandar',   'Kota Kinabalu', ST_Point(116.0735, 5.9804)::geography, true),
  ('Sepanggar',          'pekan',    'Kota Kinabalu', ST_Point(116.1147, 6.0333)::geography, false),
  ('Kg Kepayan Baru',    'kampung',  'Kota Kinabalu', ST_Point(116.0900, 5.9200)::geography, false),
  ('Tuaran',             'pekan',    'Tuaran',        ST_Point(116.2264, 6.1775)::geography, true),
  ('Tamparuli',          'junction', 'Tuaran',        ST_Point(116.2500, 6.1500)::geography, true),
  ('Ranau',              'pekan',    'Ranau',         ST_Point(116.6667, 5.9500)::geography, true),
  ('Telupid',            'junction', 'Telupid',       ST_Point(117.1333, 5.6333)::geography, true),
  ('Beluran',            'pekan',    'Beluran',       ST_Point(117.5333, 5.8667)::geography, true),
  ('Kg Muasnad',         'kampung',  'Beluran',       ST_Point(117.5100, 5.8900)::geography, false);

-- Edges are bidirectional pairs; distances are curated, not API-derived,
-- because they feed the pricing engine and must not drift.
```

### 17.3 Commission (deck-confirmed: 25 %)

```sql
-- CONFIRMED: 25% of order total to the platform.
-- Deck arithmetic is unambiguous: RM50 pesanan x 25% = RM12.50 hasil.
INSERT INTO internal.commission_rules
  (party, basis, rate_bps, max_commission_sen, effective_from)
VALUES
  ('platform', 'order_total', 2500, NULL, now());
```

`order_total` = goods budget cap + delivery fee, i.e. everything the requester pays.
`max_commission_sen` is left `NULL` to match the deck exactly. It exists so that a cap
can be introduced later — for high-value `BELI` orders where 25 % of goods value is
large relative to the physical work — as a single row insert with a new
`effective_from`, never a migration.

### 17.4 Pricing rules v1 (assumed — PRD A-04/A-05)

```sql
INSERT INTO internal.pricing_rules (version, effective_from, params) VALUES (1, now(), '{
  "base_fare_sen": 500,
  "per_kg_sen": 150,
  "included_kg": 1,
  "volumetric_divisor": 5000,
  "corridor_band_km":  {"local": 25, "district": 80, "regional": 150},
  "corridor_band_sen": {"local": 0, "district": 300, "regional": 500, "long_haul": 800},
  "cod_handling_sen": 100,
  "handling_surcharge_sen": {
    "FRAGILE": 200, "COLD_CHAIN": 300, "LIVE_ANIMAL": 500,
    "OVERSIZED": 600, "PERISHABLE": 100, "LIQUID": 200
  },
  "max_budget_cap_sen": 25000
}'::jsonb);

-- Worked check against the deck (Beluran -> KK, 266 km, 2 kg seafood):
--   base 500 + long_haul 800 + weight 150 + handling (perish 100 + cold 300) = 1850
--   Hmm: 1850 with cold chain. For a non-cold 2kg parcel: 500+800+150+100 = 1550.
--   goods 3500 + delivery 1550 = 5050 order  ->  commission 1263  (deck: 5000 / 1250)
-- Distance is BANDED, not metered: the carrier is already making the trip.
```

---

## 18. Entity relationships

```
                          profiles ──┬── user_roles
                              │       ├── community_members ── communities ── route_nodes
                              │       ├── devices
                              │       ├── addresses ──────────── route_nodes
                              │       ├── user_badges ── badge_definitions
                              │       └── voucher_issuances ── voucher_campaigns
                              │
              ┌───────────────┼───────────────┬──────────────┐
              ▼               ▼               ▼              ▼
          carriers        sellers          agents      (customer role)
              │               │               │              │
          vehicles        products           hub             │
              │               │                              │
            trips ◄──── trip_reservations ────► kirim_requests ◄── quotes
              │                                      │  │
              │                                      │  └── price_variances   (BELI)
              │                                      │
              └──────────────► deliveries ◄──────────┘
                                  │
              ┌───────────────────┼────────────────┬──────────────┐
              ▼                   ▼                ▼              ▼
      delivery_events      handover_codes       proofs        disputes
       (partitioned)        + nonces                              │
                                                                  ▼
                                                          conversations ── messages

   internal (unreachable from any client JWT):
      ledger_accounts ── ledger_transactions ── ledger_entries
      payments ── webhook_events ── payouts ── bank_accounts ── cod_collections
      pricing_rules ── commission_rules ── quotes ── idempotency_keys

   audit:  audit_logs (partitioned, append-only, 7-year retention)
```

---

## 19. Migration policy

1. **Forward-only.** No destructive down migrations in production. A mistake is corrected by a new migration.
2. **Expand / contract** for column changes: add nullable → backfill → dual-write → switch reads → drop old. Never rename in a single step.
3. **Every migration ships with its RLS policies.** A table added without policies fails CI (§`TESTING.md`).
4. **`CONCURRENTLY`** for index creation on populated tables.
5. **Reversibility rehearsal:** every migration is applied to a PITR restore of production before it reaches production.
6. **No data migration inside a schema migration** — long-running backfills run as separate, resumable jobs.
7. **Financial tables are append-only in migrations too.** A migration that would `UPDATE internal.ledger_entries` is rejected in review, without exception.
