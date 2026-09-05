-- ============================================================================
-- KasihKirim — 0002_supporting_entities.sql
-- Requires 0000 (auth helpers) and 0001 (base tables).
-- Closes the seven specification gaps found in the architecture review.
--
-- ORDERING NOTE (fixes the circular-FK problem):
--   0001 must create tables in this order, with FKs added afterwards:
--     1. ref.route_nodes           (no deps)
--     2. ref.route_edges, ref.zones, ref.categories
--     3. public.communities         -> route_nodes
--     4. auth.users trigger -> public.profiles  (home_community_id FK ADDED LATER)
--     5. public.agents              -> profiles, communities
--     6. ALTER public.profiles ADD FK home_community_id -> communities
--     7. public.addresses           -> profiles, communities, route_nodes, agents
--   i.e. profiles.home_community_id and addresses.agent_hub_id are added by
--   ALTER after their targets exist. Never inline in CREATE TABLE.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. agents — community hub operators (FR-290..295)
--    Referenced by addresses.agent_hub_id. Schema will not build without it.
-- ---------------------------------------------------------------------------
CREATE TABLE public.agents (
  id                  UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id             UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE RESTRICT,
  community_id        UUID NOT NULL REFERENCES public.communities(id),
  hub_name            TEXT NOT NULL,
  hub_address_note    TEXT NOT NULL,
  geog                GEOGRAPHY(POINT,4326),
  status              ref.verification_status NOT NULL DEFAULT 'NOT_STARTED',
  commission_bps      INT NOT NULL DEFAULT 0 CHECK (commission_bps BETWEEN 0 AND 10000),
  flat_fee_sen        BIGINT NOT NULL DEFAULT 100,      -- A-03: RM1.00 per parcel
  cash_float_limit_sen BIGINT NOT NULL DEFAULT 100000,
  cash_held_sen       BIGINT NOT NULL DEFAULT 0 CHECK (cash_held_sen >= 0),
  parcels_handled     INT NOT NULL DEFAULT 0,
  verified_at         TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_agent_float CHECK (cash_held_sen <= cash_float_limit_sen)
);
CREATE INDEX ix_agents_community ON public.agents(community_id) WHERE status = 'APPROVED';

-- One approved hub per community at launch.
CREATE UNIQUE INDEX ux_agent_one_per_community
  ON public.agents(community_id) WHERE status = 'APPROVED';

ALTER TABLE public.addresses
  ADD CONSTRAINT fk_addresses_agent_hub
  FOREIGN KEY (agent_hub_id) REFERENCES public.agents(id);

-- ---------------------------------------------------------------------------
-- 2. delivery_offers — the offer/accept flow (API.md §4.5)
-- ---------------------------------------------------------------------------
CREATE TYPE ref.offer_status AS ENUM
  ('PENDING','ACCEPTED','DECLINED','EXPIRED','WITHDRAWN','COUNTERED');

CREATE TYPE ref.offer_direction AS ENUM
  ('CARRIER_TO_KIRIM','KIRIM_TO_TRIP');

CREATE TABLE public.delivery_offers (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  kirim_id         UUID NOT NULL REFERENCES public.kirim_requests(id) ON DELETE RESTRICT,
  trip_id          UUID NOT NULL REFERENCES public.trips(id) ON DELETE RESTRICT,
  carrier_id       UUID NOT NULL REFERENCES public.carriers(id),
  direction        ref.offer_direction NOT NULL,
  status           ref.offer_status NOT NULL DEFAULT 'PENDING',
  offered_fee_sen  BIGINT NOT NULL CHECK (offered_fee_sen >= 0),
  quoted_fee_sen   BIGINT NOT NULL,          -- system quote at time of offer
  match_score      INT CHECK (match_score BETWEEN 0 AND 100),
  detour_km        NUMERIC(6,2),
  reservation_id   UUID REFERENCES public.trip_reservations(id),
  message          TEXT CHECK (length(message) <= 300),
  countered_from   UUID REFERENCES public.delivery_offers(id),
  expires_at       TIMESTAMPTZ NOT NULL,
  responded_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- BR-906: negotiated price must stay inside the ±20% band of the quote.
  CONSTRAINT ck_offer_band CHECK (
    offered_fee_sen BETWEEN (quoted_fee_sen * 80 / 100) AND (quoted_fee_sen * 120 / 100)
  )
);

-- One live offer per (kirim, carrier) at a time.
CREATE UNIQUE INDEX ux_offer_active
  ON public.delivery_offers(kirim_id, carrier_id) WHERE status = 'PENDING';
CREATE INDEX ix_offers_kirim  ON public.delivery_offers(kirim_id, status);
CREATE INDEX ix_offers_trip   ON public.delivery_offers(trip_id, status);
CREATE INDEX ix_offers_expiry ON public.delivery_offers(expires_at) WHERE status = 'PENDING';

-- ---------------------------------------------------------------------------
-- 3. carts — server-held cart (FR-182, API.md §4.10)
-- ---------------------------------------------------------------------------
CREATE TABLE public.carts (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  user_id     UUID NOT NULL UNIQUE REFERENCES public.profiles(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.cart_items (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  cart_id     UUID NOT NULL REFERENCES public.carts(id) ON DELETE CASCADE,
  product_id  UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  quantity    INT NOT NULL CHECK (quantity > 0 AND quantity <= 999),
  added_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (cart_id, product_id)
);
CREATE INDEX ix_cart_items_cart ON public.cart_items(cart_id);

-- Cart holds NO prices. Price is resolved server-side at checkout from the
-- live product row, then snapshotted into order_items. (BR-900)

-- ---------------------------------------------------------------------------
-- 4. app_config — runtime config, force-upgrade gate, all TTLs
-- ---------------------------------------------------------------------------
CREATE TABLE ref.app_config (
  key          TEXT PRIMARY KEY,
  value        JSONB NOT NULL,
  description  TEXT,
  updated_by   UUID,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO ref.app_config (key, value, description) VALUES
  ('min_supported_version',   '"1.0.0"',  'Hard 426 gate below this'),
  ('latest_version',          '"1.0.0"',  'Soft update prompt'),
  ('settlement_window_hours', '48',       'A-07 fallback if recipient never confirms'),
  ('quote_ttl_minutes',       '15',       'A-12'),
  ('offer_ttl_hours',         '2',        'A-12'),
  ('capacity_hold_ttl_minutes','30',      'A-12'),
  ('variance_ttl_hours',      '2',        'Timeout => DECLINE (safe default)'),
  ('offer_band_bps',          '2000',     'A-11 +/-20%'),
  ('max_budget_cap_sen',      '25000',    'C-03 RM250 ceiling'),
  ('max_declared_value_sen',  '100000',   'A-15 pending LGL-08'),
  ('review_reveal_days',      '7',        'A-14 double-blind window'),
  ('payout_minimum_sen',      '2000',     'A-08 RM20'),
  ('default_float_limit_sen', '50000',    'A-09 RM500'),
  ('max_detour_km',           '10',       'Default; 25 for 4WD'),
  ('payment_methods_enabled', '["COD"]',  'Prepaid gated on LGL-02'),
  ('feature_flags',           '{"marketplace":false,"prepaid_payments":false,"agent_hubs":false}', NULL),
  ('match_weights',           '{"corridor":35,"capacity":15,"timing":15,"quality":15,"price":10,"locality":10}', 'ARCHITECTURE.md 6.2');

-- ---------------------------------------------------------------------------
-- 5. match_results — board ranking cache (ARCHITECTURE.md §6.2)
-- ---------------------------------------------------------------------------
CREATE TABLE internal.match_results (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  anchor_type   TEXT NOT NULL CHECK (anchor_type IN ('trip','kirim')),
  anchor_id     UUID NOT NULL,
  counterpart_id UUID NOT NULL,
  match_score   INT NOT NULL CHECK (match_score BETWEEN 0 AND 100),
  corridor_fit  INT NOT NULL,
  detour_km     NUMERIC(6,2) NOT NULL DEFAULT 0,
  capacity_fit  INT NOT NULL,
  timing_fit    INT NOT NULL,
  computed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '5 minutes'
);
CREATE UNIQUE INDEX ux_match_pair ON internal.match_results(anchor_type, anchor_id, counterpart_id);
CREATE INDEX ix_match_anchor ON internal.match_results(anchor_type, anchor_id, match_score DESC);
CREATE INDEX ix_match_expiry ON internal.match_results(expires_at);

-- ---------------------------------------------------------------------------
-- 6. delivery_tracking_points — partitioned, 30-day retention (NFR / PDPA)
-- ---------------------------------------------------------------------------
CREATE TABLE public.delivery_tracking_points (
  id           UUID NOT NULL DEFAULT uuidv7(),
  trip_id      UUID NOT NULL,
  carrier_id   UUID NOT NULL,
  geog         GEOGRAPHY(POINT,4326) NOT NULL,
  accuracy_m   INT,
  speed_kmh    NUMERIC(5,1),
  battery_pct  INT CHECK (battery_pct BETWEEN 0 AND 100),
  recorded_at  TIMESTAMPTZ NOT NULL,
  received_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (id, recorded_at)
) PARTITION BY RANGE (recorded_at);

CREATE INDEX ix_tracking_trip ON public.delivery_tracking_points(trip_id, recorded_at DESC);

-- ---------------------------------------------------------------------------
-- 7. cancellation_policies — BR-905
-- ---------------------------------------------------------------------------
CREATE TABLE ref.cancellation_policies (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  applies_to_status  ref.kirim_status NOT NULL,
  cancelled_by       ref.user_role NOT NULL,
  kirim_type         ref.kirim_type,
  fee_bps            INT NOT NULL DEFAULT 0 CHECK (fee_bps BETWEEN 0 AND 10000),
  flat_fee_sen       BIGINT NOT NULL DEFAULT 0,
  refund_goods       BOOLEAN NOT NULL DEFAULT true,
  penalty_points     INT NOT NULL DEFAULT 0,
  effective_from     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (applies_to_status, cancelled_by, kirim_type)
);

INSERT INTO ref.cancellation_policies
  (applies_to_status, cancelled_by, fee_bps, flat_fee_sen, refund_goods, penalty_points) VALUES
  ('POSTED',          'customer', 0,    0,   true,  0),   -- free before match
  ('MATCHED',         'customer', 0,    200, true,  0),   -- RM2 admin
  ('PROCURING',       'customer', 0,    200, true,  0),   -- free: goods not yet bought
  ('AWAITING_PICKUP', 'customer', 2000, 0,   true,  1),
  ('IN_TRANSIT',      'customer', 5000, 0,   true,  2),
  ('MATCHED',         'carrier',  0,    0,   true,  2),   -- carrier bears rating cost
  ('AWAITING_PICKUP', 'carrier',  0,    0,   true,  3),
  ('IN_TRANSIT',      'carrier',  0,    0,   true,  5);

-- Goods already purchased under BELI are NEVER refundable to the requester at
-- the carrier's expense: fn_cancel evaluates actual_goods_sen and settles the
-- carrier's reimbursement regardless of who cancelled. (BR-913 corollary)

-- ---------------------------------------------------------------------------
-- 8. RLS — every new table, default deny
-- ---------------------------------------------------------------------------
ALTER TABLE public.agents                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_offers          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carts                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cart_items               ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_tracking_points ENABLE ROW LEVEL SECURITY;

CREATE POLICY agents_select ON public.agents FOR SELECT TO authenticated
  USING (status = 'APPROVED' OR user_id = (SELECT auth.uid()) OR authz.is_admin());

CREATE POLICY offers_select ON public.delivery_offers FOR SELECT TO authenticated
  USING (
    carrier_id = authz.my_carrier_id()
    OR EXISTS (SELECT 1 FROM public.kirim_requests k
               WHERE k.id = delivery_offers.kirim_id
                 AND k.requester_id = (SELECT auth.uid()))
    OR authz.is_admin()
  );
-- No INSERT/UPDATE policy: offers are created and resolved only by
-- internal.fn_make_offer / fn_accept_offer. (BR-904 pattern)
REVOKE INSERT, UPDATE, DELETE ON public.delivery_offers FROM authenticated, anon;

CREATE POLICY carts_own ON public.carts FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY cart_items_own ON public.cart_items FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.carts c
                 WHERE c.id = cart_items.cart_id AND c.user_id = (SELECT auth.uid())))
  WITH CHECK (EXISTS (SELECT 1 FROM public.carts c
                      WHERE c.id = cart_items.cart_id AND c.user_id = (SELECT auth.uid())));

CREATE POLICY tracking_select ON public.delivery_tracking_points FOR SELECT TO authenticated
  USING (
    carrier_id = authz.my_carrier_id()
    OR EXISTS (SELECT 1 FROM public.deliveries d
               JOIN public.kirim_requests k ON k.id = d.kirim_id
               WHERE d.trip_id = delivery_tracking_points.trip_id
                 AND k.requester_id = (SELECT auth.uid())
                 AND d.status IN ('IN_TRANSIT','OUT_FOR_DELIVERY'))
    OR authz.is_admin()
  );
REVOKE UPDATE, DELETE ON public.delivery_tracking_points FROM authenticated, anon;

-- ref.app_config and ref.cancellation_policies are read-only reference data.
GRANT SELECT ON ref.app_config, ref.cancellation_policies TO authenticated;
