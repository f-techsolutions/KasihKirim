-- ============================================================================
-- KasihKirim — 0007_sabah_geography_compliance.sql
--
-- Implements the additional business requirements:
--   §1,§22  Sabah geography as CONFIGURATION, not seed. Beluran is data.
--   §2      Rural address model: district, mukim, kampung, landmark, coords.
--   §6,§18  Category-level compliance controls, changeable without a release.
--   §7,§8   Seller onboarding and licence expiry.
--   §10     Configurable product approval policy.
--   §20     Four independent gates + compliance_status.
--   §23     Pricing configurable by district and route.
--
-- Muatan Jual is BUILT and GATED, never deleted. See MUATAN-JUAL-COMPLIANCE.md.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- §1 / §22 — GEOGRAPHY HIERARCHY
-- region → district → mukim → community → pickup point
-- Expansion to a new Sabah district becomes an INSERT, not a migration.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE ref.regions (
  id         UUID PRIMARY KEY DEFAULT uuidv7(),
  code       TEXT NOT NULL UNIQUE,
  name       TEXT NOT NULL,
  country    TEXT NOT NULL DEFAULT 'MY',
  timezone   TEXT NOT NULL DEFAULT 'Asia/Kuching',
  is_active  BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE ref.districts (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  region_id   UUID NOT NULL REFERENCES ref.regions(id),
  code        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  -- Sabah local authority. Trading licences are issued per district
  -- (Local Government Ordinance 1961). See MUATAN-JUAL-COMPLIANCE.md §11.
  local_authority TEXT,
  centroid    GEOGRAPHY(POINT,4326),
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (region_id, name)
);

CREATE TABLE ref.mukims (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  district_id UUID NOT NULL REFERENCES ref.districts(id),
  name        TEXT NOT NULL,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  UNIQUE (district_id, name)
);

-- A service area is an OPERATIONAL decision, separate from geography.
-- Activating Paitan is an UPDATE here, not a deployment.
CREATE TYPE ref.service_area_status AS ENUM
  ('PLANNED','PILOT','ACTIVE','SUSPENDED','CLOSED');

CREATE TABLE public.service_areas (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  district_id    UUID NOT NULL REFERENCES ref.districts(id),
  name           TEXT NOT NULL,
  status         ref.service_area_status NOT NULL DEFAULT 'PLANNED',
  supports_cod   BOOLEAN NOT NULL DEFAULT true,
  supports_prepaid BOOLEAN NOT NULL DEFAULT false,   -- gated on LGL-02
  supports_marketplace BOOLEAN NOT NULL DEFAULT false,
  activated_at   TIMESTAMPTZ,
  suspended_reason TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (district_id, name)
);
CREATE INDEX ix_service_areas_live ON public.service_areas(status)
  WHERE status IN ('PILOT','ACTIVE');

-- §2: pickup / drop-off points. Rural delivery frequently terminates at a
-- kedai, jetty or balai raya rather than a house.
CREATE TABLE public.pickup_points (
  id              UUID PRIMARY KEY DEFAULT uuidv7(),
  service_area_id UUID NOT NULL REFERENCES public.service_areas(id),
  community_id    UUID REFERENCES public.communities(id),
  agent_id        UUID REFERENCES public.agents(id),
  name            TEXT NOT NULL,
  point_type      TEXT NOT NULL CHECK (point_type IN
                    ('agent_hub','kedai','jetty','balai_raya','pekan','sekolah','other')),
  landmark_note   TEXT NOT NULL,
  geog            GEOGRAPHY(POINT,4326),
  node_id         UUID REFERENCES ref.route_nodes(id),
  opening_hours   TEXT,
  contact_phone   TEXT CHECK (contact_phone IS NULL OR contact_phone ~ '^\+60[0-9]{8,10}$'),
  is_active       BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_pickup_points_area ON public.pickup_points(service_area_id) WHERE is_active;
CREATE INDEX ix_pickup_points_geog ON public.pickup_points USING GIST(geog);

-- Link existing geography. Nullable + backfilled: expand/contract, per the
-- forward-only migration rule in DEPLOYMENT.md §5.1.
ALTER TABLE public.communities  ADD COLUMN district_id     UUID REFERENCES ref.districts(id);
ALTER TABLE public.communities  ADD COLUMN mukim_id        UUID REFERENCES ref.mukims(id);
ALTER TABLE public.communities  ADD COLUMN service_area_id UUID REFERENCES public.service_areas(id);
ALTER TABLE ref.route_nodes     ADD COLUMN district_id     UUID REFERENCES ref.districts(id);

-- §2: the rural address model.
ALTER TABLE public.addresses ADD COLUMN mukim_id             UUID REFERENCES ref.mukims(id);
ALTER TABLE public.addresses ADD COLUMN district_id          UUID REFERENCES ref.districts(id);
ALTER TABLE public.addresses ADD COLUMN pickup_point_id      UUID REFERENCES public.pickup_points(id);
ALTER TABLE public.addresses ADD COLUMN pickup_instructions  TEXT;
ALTER TABLE public.addresses ADD COLUMN recipient_instructions TEXT;

-- ════════════════════════════════════════════════════════════════════════════
-- §6 / §18 — CATEGORY COMPLIANCE
-- Compliance can close a category without an Android release.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TYPE ref.category_legal_status AS ENUM
  ('NORMAL','APPROVAL_REQUIRED','LICENCE_REQUIRED','RESTRICTED','PROHIBITED');

CREATE TABLE ref.category_compliance (
  category_id           UUID PRIMARY KEY REFERENCES ref.categories(id),
  legal_status          ref.category_legal_status NOT NULL DEFAULT 'APPROVAL_REQUIRED',
  requires_licence      BOOLEAN NOT NULL DEFAULT false,
  licence_type          TEXT,
  issuing_authority     TEXT,
  requires_listing_approval BOOLEAN NOT NULL DEFAULT true,
  required_documents    TEXT[] NOT NULL DEFAULT '{}',
  max_txn_value_sen     BIGINT,
  max_qty_per_order     NUMERIC(10,2),
  marketplace_enabled   BOOLEAN NOT NULL DEFAULT false,
  compliance_note       TEXT,
  legal_review_status   TEXT NOT NULL DEFAULT 'PENDING'
                          CHECK (legal_review_status IN ('PENDING','IN_REVIEW','CLEARED','BLOCKED')),
  reviewed_by           UUID REFERENCES public.profiles(id),
  reviewed_at           TIMESTAMPTZ,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- A prohibited category can never be marketplace-enabled, whatever an
  -- admin clicks. The database refuses the combination.
  CONSTRAINT ck_prohibited_not_enabled
    CHECK (legal_status <> 'PROHIBITED' OR marketplace_enabled = false),
  CONSTRAINT ck_licence_has_type
    CHECK (NOT requires_licence OR licence_type IS NOT NULL)
);

-- Default posture: everything closed until counsel clears it. Opening a
-- category later is cheap; unwinding an illegal sale is not.
INSERT INTO ref.category_compliance (category_id, legal_status, requires_licence,
  licence_type, issuing_authority, requires_listing_approval, marketplace_enabled,
  compliance_note)
SELECT c.id,
  CASE c.slug
    WHEN 'kraf'       THEN 'NORMAL'
    WHEN 'hasil-laut' THEN 'LICENCE_REQUIRED'
    ELSE 'APPROVAL_REQUIRED' END::ref.category_legal_status,
  c.slug = 'hasil-laut',
  CASE c.slug WHEN 'hasil-laut' THEN 'Fisheries / food handling' ELSE NULL END,
  CASE c.slug WHEN 'hasil-laut' THEN 'Sabah Department of Fisheries' ELSE NULL END,
  c.slug <> 'kraf',
  false,          -- nothing marketplace-enabled at launch
  'MJ-04: category determination pending. See MUATAN-JUAL-COMPLIANCE.md §9.'
FROM ref.categories c
ON CONFLICT (category_id) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- §7 / §8 — SELLER ONBOARDING AND LICENCES
-- ════════════════════════════════════════════════════════════════════════════
CREATE TYPE ref.seller_onboarding_status AS ENUM
  ('PENDING','DOCUMENT_REVIEW','APPROVED','ACTIVE','REJECTED','SUSPENDED','EXPIRED');

ALTER TABLE public.sellers
  ADD COLUMN onboarding_status ref.seller_onboarding_status NOT NULL DEFAULT 'PENDING',
  ADD COLUMN seller_kind TEXT NOT NULL DEFAULT 'individual'
    CHECK (seller_kind IN ('individual','sole_prop','company','cooperative','carrier_trader')),
  ADD COLUMN service_area_id UUID REFERENCES public.service_areas(id),
  ADD COLUMN operating_address TEXT,
  ADD COLUMN rejection_reason TEXT,
  ADD COLUMN suspended_until TIMESTAMPTZ,
  ADD COLUMN terms_accepted_at TIMESTAMPTZ;

CREATE TABLE public.seller_documents (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  seller_id     UUID NOT NULL REFERENCES public.sellers(id) ON DELETE CASCADE,
  doc_type      TEXT NOT NULL CHECK (doc_type IN
                  ('mykad','ssm','licence','bank_statement','premises_photo','other')),
  storage_path  TEXT NOT NULL,
  verified      BOOLEAN NOT NULL DEFAULT false,
  verified_by   UUID REFERENCES public.profiles(id),
  verified_at   TIMESTAMPTZ,
  rejection_note TEXT,
  uploaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- §8 — licence expiry blocks sales automatically.
CREATE TABLE public.seller_licences (
  id                  UUID PRIMARY KEY DEFAULT uuidv7(),
  seller_id           UUID NOT NULL REFERENCES public.sellers(id) ON DELETE CASCADE,
  category_id         UUID REFERENCES ref.categories(id),
  licence_no          TEXT NOT NULL,
  licence_type        TEXT NOT NULL,
  issuing_authority   TEXT NOT NULL,
  issue_date          DATE NOT NULL,
  expiry_date         DATE NOT NULL,
  document_path       TEXT NOT NULL,
  verification_status TEXT NOT NULL DEFAULT 'PENDING'
                        CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED','EXPIRED')),
  verified_by         UUID REFERENCES public.profiles(id),
  verified_at         TIMESTAMPTZ,
  expiry_notified_at  TIMESTAMPTZ,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_licence_dates CHECK (expiry_date > issue_date)
);
CREATE INDEX ix_licence_expiry ON public.seller_licences(expiry_date)
  WHERE verification_status = 'VERIFIED';
CREATE UNIQUE INDEX ux_licence_active
  ON public.seller_licences(seller_id, COALESCE(category_id, seller_id), licence_no)
  WHERE verification_status IN ('PENDING','VERIFIED');

CREATE TABLE public.seller_categories (
  seller_id   UUID NOT NULL REFERENCES public.sellers(id) ON DELETE CASCADE,
  category_id UUID NOT NULL REFERENCES ref.categories(id),
  status      TEXT NOT NULL DEFAULT 'PENDING'
                CHECK (status IN ('PENDING','APPROVED','REJECTED','SUSPENDED')),
  approved_by UUID REFERENCES public.profiles(id),
  approved_at TIMESTAMPTZ,
  PRIMARY KEY (seller_id, category_id)
);

-- §10 — product approval
ALTER TABLE public.products
  ADD COLUMN approval_required BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN approved_by UUID REFERENCES public.profiles(id),
  ADD COLUMN approved_at TIMESTAMPTZ,
  ADD COLUMN compliance_note TEXT;

-- ════════════════════════════════════════════════════════════════════════════
-- §20 — MULTI-GATE FEATURE FLAGS
-- Four independent switches plus a compliance lifecycle. One boolean is not
-- enough: seller onboarding must be able to open months before checkout does.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TYPE ref.compliance_status AS ENUM
  ('NOT_READY','LEGAL_REVIEW','LICENSING_IN_PROGRESS','LICENSED',
   'APPROVED_FOR_PILOT','PRODUCTION_ACTIVE','SUSPENDED');

CREATE TABLE ref.feature_gates (
  key            TEXT PRIMARY KEY,
  enabled        BOOLEAN NOT NULL DEFAULT false,
  description    TEXT NOT NULL,
  changed_by     UUID REFERENCES public.profiles(id),
  changed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  change_reason  TEXT
);

INSERT INTO ref.feature_gates (key, enabled, description) VALUES
  ('muatan_jual_enabled', false,
   'Master switch for Muatan Jual marketplace'),
  ('muatan_jual_seller_onboarding_enabled', false,
   'Seller applications and document collection'),
  ('muatan_jual_category_marketplace_enabled', false,
   'Category-level browse and discovery'),
  ('muatan_jual_checkout_enabled', false,
   'CUSTOMER MONEY MOVEMENT. Blocked by MJ-01 (escrow vs BNM).'),
  ('ajak_kirim_enabled', true,
   'Carrier capacity invites. No money, no legal gate.'),
  ('kongsi_untung_enabled', false,
   'Promoter referral programme'),
  ('prepaid_payments_enabled', false,
   'Non-COD payment methods. Blocked by MJ-01.')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE ref.compliance_state (
  id             BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),   -- single row
  status         ref.compliance_status NOT NULL DEFAULT 'NOT_READY',
  changed_by     UUID REFERENCES public.profiles(id),
  changed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  evidence_note  TEXT
);
INSERT INTO ref.compliance_state (id, status, evidence_note)
VALUES (true, 'NOT_READY', 'Initial. See MUATAN-JUAL-COMPLIANCE.md §13 checklist.')
ON CONFLICT (id) DO NOTHING;

-- ── The gate. Every marketplace RPC calls this. ─────────────────────────────
-- Raises rather than returning empty: a silent failure looks like a bug and
-- invites someone to "fix" it by removing the check.
CREATE OR REPLACE FUNCTION internal.fn_marketplace_gate(
  p_category UUID DEFAULT NULL, p_seller UUID DEFAULT NULL, p_checkout BOOLEAN DEFAULT false)
RETURNS VOID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE cs ref.compliance_status; cc ref.category_compliance;
BEGIN
  SELECT status INTO cs FROM ref.compliance_state WHERE id;
  IF cs <> 'PRODUCTION_ACTIVE' THEN
    RAISE EXCEPTION 'MARKETPLACE_NOT_ACTIVE: compliance_status=%', cs;
  END IF;

  IF NOT (SELECT enabled FROM ref.feature_gates WHERE key='muatan_jual_enabled') THEN
    RAISE EXCEPTION 'MARKETPLACE_DISABLED';
  END IF;

  IF p_checkout AND NOT (SELECT enabled FROM ref.feature_gates
                          WHERE key='muatan_jual_checkout_enabled') THEN
    RAISE EXCEPTION 'CHECKOUT_DISABLED';
  END IF;

  IF p_category IS NOT NULL THEN
    SELECT * INTO cc FROM ref.category_compliance WHERE category_id = p_category;
    IF NOT FOUND OR cc.legal_status = 'PROHIBITED' OR NOT cc.marketplace_enabled THEN
      RAISE EXCEPTION 'CATEGORY_NOT_PERMITTED';
    END IF;
  END IF;

  IF p_seller IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.sellers
                   WHERE id = p_seller AND onboarding_status = 'ACTIVE') THEN
      RAISE EXCEPTION 'SELLER_NOT_ACTIVE';
    END IF;
    -- §8: an expired licence blocks sales automatically.
    IF p_category IS NOT NULL AND cc.requires_licence THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.seller_licences l
        WHERE l.seller_id = p_seller
          AND (l.category_id = p_category OR l.category_id IS NULL)
          AND l.verification_status = 'VERIFIED'
          AND l.expiry_date >= current_date)
      THEN RAISE EXCEPTION 'SELLER_LICENCE_MISSING_OR_EXPIRED'; END IF;
    END IF;
  END IF;
END $$;

-- Daily: expire licences and notify. Sales stop on the expiry date whether or
-- not anyone reads the notification.
CREATE OR REPLACE FUNCTION internal.fn_expire_seller_licences()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE n INT := 0;
BEGIN
  UPDATE public.seller_licences SET verification_status='EXPIRED'
   WHERE verification_status='VERIFIED' AND expiry_date < current_date;
  GET DIAGNOSTICS n = ROW_COUNT;

  INSERT INTO public.notifications (user_id, channel, title_ms, body_ms, is_critical)
  SELECT s.user_id, 'orders',
         'Lesen akan tamat tempoh',
         'Lesen ' || l.licence_type || ' tamat pada ' || l.expiry_date ||
         '. Jualan akan dihentikan selepas tarikh itu.',
         true
  FROM public.seller_licences l JOIN public.sellers s ON s.id = l.seller_id
  WHERE l.verification_status='VERIFIED'
    AND l.expiry_date BETWEEN current_date AND current_date + 30
    AND l.expiry_notified_at IS NULL;

  UPDATE public.seller_licences SET expiry_notified_at = now()
   WHERE verification_status='VERIFIED'
     AND expiry_date BETWEEN current_date AND current_date + 30
     AND expiry_notified_at IS NULL;
  RETURN n;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- §23 — DISTRICT / ROUTE PRICING OVERRIDES
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE internal.pricing_overrides (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  scope          TEXT NOT NULL CHECK (scope IN ('district','route','service_area')),
  district_id    UUID REFERENCES ref.districts(id),
  from_node_id   UUID REFERENCES ref.route_nodes(id),
  to_node_id     UUID REFERENCES ref.route_nodes(id),
  service_area_id UUID REFERENCES public.service_areas(id),
  params         JSONB NOT NULL,
  priority       INT NOT NULL DEFAULT 100,
  effective_from TIMESTAMPTZ NOT NULL DEFAULT now(),
  effective_to   TIMESTAMPTZ,
  created_by     UUID REFERENCES public.profiles(id)
);
CREATE INDEX ix_pricing_overrides_live ON internal.pricing_overrides(scope, priority)
  WHERE effective_to IS NULL;

-- ════════════════════════════════════════════════════════════════════════════
-- RLS
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.service_areas     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pickup_points     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_documents  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_licences   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.seller_categories ENABLE ROW LEVEL SECURITY;

CREATE POLICY service_areas_read ON public.service_areas FOR SELECT TO authenticated
  USING (status IN ('PILOT','ACTIVE') OR authz.is_admin());
CREATE POLICY pickup_points_read ON public.pickup_points FOR SELECT TO authenticated
  USING (is_active OR authz.is_admin());

-- KYC-class documents: owner writes, compliance reads. Every read is audited.
CREATE POLICY seller_docs_own ON public.seller_documents FOR SELECT TO authenticated
  USING (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid()))
         OR authz.has_role('admin_compliance'));
CREATE POLICY seller_docs_insert ON public.seller_documents FOR INSERT TO authenticated
  WITH CHECK (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid())));

CREATE POLICY seller_licences_own ON public.seller_licences FOR SELECT TO authenticated
  USING (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid()))
         OR authz.has_role('admin_compliance') OR authz.has_role('admin_ops'));
CREATE POLICY seller_licences_insert ON public.seller_licences FOR INSERT TO authenticated
  WITH CHECK (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid())));
-- Verification is an admin act only.
REVOKE UPDATE, DELETE ON public.seller_licences FROM authenticated, anon;

CREATE POLICY seller_cats_own ON public.seller_categories FOR SELECT TO authenticated
  USING (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid()))
         OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.seller_categories FROM authenticated, anon;

-- Compliance tables are read-only reference data; only admins mutate them,
-- and only through audited server actions.
GRANT SELECT ON ref.regions, ref.districts, ref.mukims,
                ref.category_compliance, ref.feature_gates, ref.compliance_state
  TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON ref.category_compliance, ref.feature_gates,
                                 ref.compliance_state
  FROM authenticated, anon;

-- ── Replace the single-boolean flag blob from 0006 ──────────────────────────
-- Superseded by ref.feature_gates. Kept in app_config only as a pointer so a
-- stale client reading the old key does not silently see "enabled".
UPDATE ref.app_config
   SET value = '{"see":"ref.feature_gates"}'::jsonb,
       description = 'SUPERSEDED by ref.feature_gates (0007). Do not read.'
 WHERE key = 'feature_flags';
