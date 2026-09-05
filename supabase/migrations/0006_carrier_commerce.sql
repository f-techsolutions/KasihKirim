-- ============================================================================
-- KasihKirim — 0006_carrier_commerce.sql
-- Ajak Kirim (A), Kongsi & Untung (B), Muatan Jual (C).
-- See docs/ADDENDUM-COMMERCE.md.
--
-- COMMERCIAL DECISIONS ENCODED HERE
--   Muatan Jual : 10% of goods value + 25% of any attached delivery fee
--   Promoter    : 25% of platform commission, capped RM10, from platform share
--   Inventory   : carrier capital only; the platform funds nothing
--   Seller of record : the carrier
--
-- Muatan Jual ships behind a feature flag, default OFF. The schema is ready;
-- the feature stays closed until LGL-02/13/14/15 are answered.
-- ============================================================================

-- ── Commission context: one rule table now serves three products ────────────
ALTER TABLE internal.commission_rules
  ADD COLUMN context TEXT NOT NULL DEFAULT 'kirim'
    CHECK (context IN ('kirim','muatan_jual','promoter'));

-- 'promoter' is a distinct party: a promoter need not be a carrier.
ALTER TABLE internal.commission_rules DROP CONSTRAINT commission_rules_party_check;
ALTER TABLE internal.commission_rules ADD CONSTRAINT commission_rules_party_check
  CHECK (party IN ('platform','agent','carrier','promoter'));

DROP INDEX IF EXISTS ux_commission_active;
-- basis MUST be in the key: muatan_jual charges platform commission on BOTH
-- goods_subtotal (10%) and delivery_fee (25%). Without basis the second insert
-- is rejected and the unbundled pricing silently collapses to one rule.
CREATE UNIQUE INDEX ux_commission_active
  ON internal.commission_rules (context, party, basis, COALESCE(kirim_type::text,'*'))
  WHERE effective_to IS NULL;

-- ════════════════════════════════════════════════════════════════════════════
-- FEATURE A — Ajak Kirim
-- No money. Creates a normal Kirim through the existing flow.
-- Directly targets trip fill rate, which is what makes RM2.50/parcel viable.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TYPE ref.invite_audience AS ENUM ('community','past_senders','specific_user');

CREATE TABLE public.capacity_invites (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  trip_id        UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  carrier_id     UUID NOT NULL REFERENCES public.carriers(id),
  audience       ref.invite_audience NOT NULL,
  community_id   UUID REFERENCES public.communities(id),
  target_user_id UUID REFERENCES public.profiles(id),
  message        TEXT CHECK (length(message) <= 200),
  sent_count     INT NOT NULL DEFAULT 0,
  response_count INT NOT NULL DEFAULT 0,
  expires_at     TIMESTAMPTZ NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (audience <> 'community'     OR community_id   IS NOT NULL),
  CHECK (audience <> 'specific_user' OR target_user_id IS NOT NULL)
);

-- FR-404. An invite is an unsolicited push aimed at getting someone to spend
-- money. Uncapped, users mute the app — taking delivery_critical with it. The
-- cap protects the notification channel, so it lives in the database.
CREATE UNIQUE INDEX ux_invite_per_trip_audience
  ON public.capacity_invites (trip_id, audience,
                              COALESCE(community_id, target_user_id, trip_id));

CREATE INDEX ix_invite_expiry ON public.capacity_invites(expires_at);

CREATE TABLE public.invite_responses (
  invite_id    UUID NOT NULL REFERENCES public.capacity_invites(id) ON DELETE CASCADE,
  user_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kirim_id     UUID REFERENCES public.kirim_requests(id),
  responded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (invite_id, user_id)
);

CREATE TABLE public.restock_requests (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id  UUID NOT NULL REFERENCES public.carriers(id) ON DELETE CASCADE,
  supplier_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  product_id  UUID REFERENCES public.products(id),
  description TEXT NOT NULL CHECK (length(description) BETWEEN 3 AND 300),
  qty_note    TEXT NOT NULL,
  needed_by   DATE,
  status      TEXT NOT NULL DEFAULT 'PENDING'
                CHECK (status IN ('PENDING','ACCEPTED','DECLINED','EXPIRED')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_restock_not_self CHECK (true)   -- trigger below
);

CREATE OR REPLACE FUNCTION internal.tg_restock_not_self()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.carriers c
             WHERE c.id = NEW.carrier_id AND c.user_id = NEW.supplier_id) THEN
    RAISE EXCEPTION 'SELF_DEALING';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_restock_self BEFORE INSERT ON public.restock_requests
  FOR EACH ROW EXECUTE FUNCTION internal.tg_restock_not_self();

-- ════════════════════════════════════════════════════════════════════════════
-- FEATURE B — Kongsi & Untung
-- Promoter is paid a SHARE OF PLATFORM COMMISSION, never a slice of order
-- total. A flat bps on order total would have eaten ~30% of platform revenue
-- on a Muatan Jual sale; this scales and can never make a sale unprofitable.
-- ════════════════════════════════════════════════════════════════════════════
CREATE TABLE public.promotions (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  promoter_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  subject_type   TEXT NOT NULL CHECK (subject_type IN ('product','seller','lot')),
  subject_id     UUID NOT NULL,
  code           TEXT NOT NULL UNIQUE,
  is_active      BOOLEAN NOT NULL DEFAULT true,
  click_count    INT NOT NULL DEFAULT 0,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (promoter_id, subject_type, subject_id)
);
CREATE INDEX ix_promotions_code ON public.promotions(code) WHERE is_active;

CREATE TABLE public.promotion_attributions (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  promotion_id     UUID NOT NULL REFERENCES public.promotions(id),
  buyer_id         UUID NOT NULL REFERENCES public.profiles(id),
  order_id         UUID REFERENCES public.orders(id),
  kirim_id         UUID REFERENCES public.kirim_requests(id),
  order_total_sen  BIGINT NOT NULL CHECK (order_total_sen > 0),
  platform_commission_sen BIGINT NOT NULL CHECK (platform_commission_sen >= 0),
  promoter_sen     BIGINT NOT NULL CHECK (promoter_sen >= 0),
  status           TEXT NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','SETTLED','REVERSED')),
  attributed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- The promoter can never be paid more than the platform earned.
  CONSTRAINT ck_promoter_within_commission
    CHECK (promoter_sen <= platform_commission_sen),
  CONSTRAINT ck_attribution_subject
    CHECK (order_id IS NOT NULL OR kirim_id IS NOT NULL)
);
CREATE UNIQUE INDEX ux_attribution_per_order
  ON public.promotion_attributions (COALESCE(order_id, kirim_id));

-- BR-910 extension. A CHECK cannot reach another table.
CREATE OR REPLACE FUNCTION internal.tg_block_self_referral()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.promotions p
             WHERE p.id = NEW.promotion_id AND p.promoter_id = NEW.buyer_id) THEN
    RAISE EXCEPTION 'SELF_REFERRAL_BLOCKED';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_attribution_self BEFORE INSERT ON public.promotion_attributions
  FOR EACH ROW EXECUTE FUNCTION internal.tg_block_self_referral();

-- ════════════════════════════════════════════════════════════════════════════
-- FEATURE C — Muatan Jual  (schema ready, feature flag OFF)
-- ════════════════════════════════════════════════════════════════════════════
CREATE TYPE ref.lot_status AS ENUM
  ('DRAFT','ACTIVE','SOLD_OUT','EXPIRED','WITHDRAWN','WRITTEN_OFF');

CREATE TABLE public.carrier_stock_lots (
  id                 UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id         UUID NOT NULL REFERENCES public.carriers(id) ON DELETE RESTRICT,
  seller_id          UUID NOT NULL REFERENCES public.sellers(id),
  trip_id            UUID REFERENCES public.trips(id),
  title              TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
  category_id        UUID NOT NULL REFERENCES ref.categories(id),
  handling_flags     ref.handling_flag[] NOT NULL DEFAULT '{}',
  unit               TEXT NOT NULL DEFAULT 'kg',
  qty_total          NUMERIC(10,2) NOT NULL CHECK (qty_total > 0),
  qty_reserved       NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (qty_reserved >= 0),
  qty_sold           NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (qty_sold >= 0),
  -- Private to carrier and admin (FR-447). Buyers see price, never margin.
  cost_basis_sen     BIGINT NOT NULL CHECK (cost_basis_sen >= 0),
  cost_receipt_path  TEXT NOT NULL,
  source_seller_id   UUID REFERENCES public.sellers(id),
  price_per_unit_sen BIGINT NOT NULL CHECK (price_per_unit_sen > 0),
  photo_paths        TEXT[] NOT NULL DEFAULT '{}',
  status             ref.lot_status NOT NULL DEFAULT 'DRAFT',
  sell_by            TIMESTAMPTZ,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Overselling a physical lot is as unrecoverable as overbooking a truck.
  -- Same three-layer guard as BR-903: lock, constraint, then app logic.
  CONSTRAINT ck_lot_not_oversold CHECK (qty_reserved + qty_sold <= qty_total),
  CONSTRAINT ck_lot_perishable_window
    CHECK (NOT ('PERISHABLE' = ANY(handling_flags)) OR sell_by IS NOT NULL)
);
CREATE INDEX ix_lots_active ON public.carrier_stock_lots(trip_id, status)
  WHERE status = 'ACTIVE';
CREATE INDEX ix_lots_expiry ON public.carrier_stock_lots(sell_by)
  WHERE status = 'ACTIVE';

CREATE TABLE public.trip_listings (
  id           UUID PRIMARY KEY DEFAULT uuidv7(),
  lot_id       UUID NOT NULL REFERENCES public.carrier_stock_lots(id) ON DELETE CASCADE,
  trip_id      UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  from_node_id UUID REFERENCES ref.route_nodes(id),
  to_node_id   UUID REFERENCES ref.route_nodes(id),
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (lot_id, trip_id)
);

-- FR-448: COD cash, procurement advances and unsold stock are three kinds of
-- the same exposure. One limit, one constraint.
ALTER TABLE public.carriers
  ADD COLUMN inventory_at_risk_sen BIGINT NOT NULL DEFAULT 0
    CHECK (inventory_at_risk_sen >= 0);

ALTER TABLE public.carriers DROP CONSTRAINT ck_carrier_exposure;
ALTER TABLE public.carriers ADD CONSTRAINT ck_carrier_exposure
  CHECK (cod_held_sen + procurement_advance_sen + inventory_at_risk_sen
         <= float_limit_sen);

-- ════════════════════════════════════════════════════════════════════════════
-- Commission rules
-- ════════════════════════════════════════════════════════════════════════════
-- Muatan Jual: 10% on goods. At 15% the carrier's break-even sell-through hits
-- 78% and an ordinary bad day on perishables becomes a loss — they stop
-- listing, and 15% of nothing is nothing.
INSERT INTO internal.commission_rules
  (context, party, basis, rate_bps, max_commission_sen, effective_from)
VALUES ('muatan_jual','platform','goods_subtotal',1000, NULL, now());

-- The delivery leg of a Muatan Jual sale still earns the full service rate.
-- Unbundling captures more than any single blended number would.
INSERT INTO internal.commission_rules
  (context, party, basis, rate_bps, max_commission_sen, effective_from)
VALUES ('muatan_jual','platform','delivery_fee',2500, NULL, now());

-- Promoter: a share of what the platform earned, capped at RM10.
INSERT INTO internal.commission_rules
  (context, party, basis, rate_bps, max_commission_sen, effective_from)
VALUES ('promoter','promoter','flat',2500, 1000, now());

-- ════════════════════════════════════════════════════════════════════════════
-- Functions
-- ════════════════════════════════════════════════════════════════════════════

/** Ajak Kirim. Capacity is read LIVE at send time (FR-402): inviting people
 *  into space that has already gone is a fast way to lose a village. */
CREATE OR REPLACE FUNCTION public.rpc_send_capacity_invite(
  p_trip UUID, p_audience TEXT, p_community UUID DEFAULT NULL,
  p_target UUID DEFAULT NULL, p_message TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_carrier UUID := authz.my_carrier_id(); t public.trips;
  v_invite UUID; v_free_g INT; v_sent INT := 0;
BEGIN
  IF v_carrier IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO t FROM public.trips WHERE id = p_trip AND carrier_id = v_carrier;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRIP_NOT_FOUND'; END IF;
  IF t.status NOT IN ('ANNOUNCED','BOARDING') THEN
    RAISE EXCEPTION 'TRIP_NOT_BOARDING'; END IF;

  v_free_g := t.capacity_weight_grams - t.reserved_weight_grams;
  IF v_free_g <= 0 THEN RAISE EXCEPTION 'CAPACITY_EXCEEDED'; END IF;

  -- ux_invite_per_trip_audience raises on the second invite to the same
  -- audience for this trip. FR-404 enforced by the database, not the UI.
  INSERT INTO public.capacity_invites
    (trip_id, carrier_id, audience, community_id, target_user_id, message, expires_at)
  VALUES (p_trip, v_carrier, p_audience::ref.invite_audience,
          p_community, p_target, p_message, t.depart_at)
  RETURNING id INTO v_invite;

  -- Low-importance channel only. Never delivery_critical.
  WITH aud AS (
    SELECT DISTINCT cm.user_id FROM public.community_members cm
     WHERE p_audience='community' AND cm.community_id = p_community
    UNION
    SELECT DISTINCT k.requester_id FROM public.kirim_requests k
      JOIN public.deliveries d ON d.kirim_id = k.id
     WHERE p_audience='past_senders' AND d.carrier_id = v_carrier
       AND d.status = 'COMPLETED'
    UNION
    SELECT p_target WHERE p_audience='specific_user'
  )
  INSERT INTO public.notifications
    (user_id, channel, title_ms, body_ms, deep_link, is_critical)
  SELECT a.user_id, 'promotions',
         'Ada ruang kosong ke ' || (SELECT name FROM ref.route_nodes WHERE id=t.dest_node_id),
         COALESCE(p_message, 'Ada ' || (v_free_g/1000) || ' kg kosong. Ada apa-apa nak dikirim?'),
         '/kirim-baru?trip=' || p_trip::text, false
  FROM aud a
  WHERE a.user_id IS NOT NULL
    AND a.user_id <> (SELECT user_id FROM public.carriers WHERE id = v_carrier)
    -- FR-404: one invite per recipient per 24h, across all carriers.
    AND NOT EXISTS (
      SELECT 1 FROM public.notifications n
       WHERE n.user_id = a.user_id AND n.channel='promotions'
         AND n.created_at > now() - INTERVAL '24 hours');

  GET DIAGNOSTICS v_sent = ROW_COUNT;
  UPDATE public.capacity_invites SET sent_count = v_sent WHERE id = v_invite;

  RETURN jsonb_build_object('invite_id', v_invite, 'sent', v_sent,
                            'free_kg', round(v_free_g/1000.0, 1));
END $$;

/** Muatan Jual purchase. Same lock-then-constraint shape as trip capacity. */
CREATE OR REPLACE FUNCTION public.rpc_buy_from_lot(
  p_lot UUID, p_qty NUMERIC, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  lot public.carrier_stock_lots; v_uid UUID := auth.uid();
  v_goods BIGINT; v_comm BIGINT; v_rate INT;
BEGIN
  IF NOT (SELECT (value->>'muatan_jual')::boolean FROM ref.app_config
           WHERE key='feature_flags') THEN
    RAISE EXCEPTION 'FEATURE_DISABLED';
  END IF;

  SELECT * INTO lot FROM public.carrier_stock_lots WHERE id = p_lot FOR UPDATE;
  IF NOT FOUND OR lot.status <> 'ACTIVE' THEN RAISE EXCEPTION 'LOT_UNAVAILABLE'; END IF;
  IF lot.sell_by IS NOT NULL AND lot.sell_by < now() THEN
    RAISE EXCEPTION 'LOT_EXPIRED'; END IF;
  -- BR-910: a carrier cannot buy their own stock.
  IF EXISTS (SELECT 1 FROM public.carriers c
             WHERE c.id = lot.carrier_id AND c.user_id = v_uid) THEN
    RAISE EXCEPTION 'SELF_DEALING'; END IF;

  IF lot.qty_reserved + lot.qty_sold + p_qty > lot.qty_total THEN
    RAISE EXCEPTION 'CAPACITY_EXCEEDED';   -- ck_lot_not_oversold backs this up
  END IF;

  v_goods := (lot.price_per_unit_sen * p_qty)::bigint;

  SELECT rate_bps INTO v_rate FROM internal.commission_rules
   WHERE context='muatan_jual' AND basis='goods_subtotal' AND effective_to IS NULL
   ORDER BY effective_from DESC LIMIT 1;
  v_comm := v_goods * v_rate / 10000;      -- 10% on goods

  UPDATE public.carrier_stock_lots
     SET qty_reserved = qty_reserved + p_qty, updated_at = now()
   WHERE id = p_lot;

  RETURN jsonb_build_object(
    'lot_id', p_lot, 'qty', p_qty,
    'goods_sen', v_goods, 'commission_sen', v_comm,
    'carrier_sen', v_goods - v_comm,
    'qty_remaining', lot.qty_total - lot.qty_reserved - lot.qty_sold - p_qty);
END $$;

/** Promoter payout: a share of platform commission, capped, from platform
 *  revenue. Never reduces what the seller or carrier receives (FR-422). */
CREATE OR REPLACE FUNCTION internal.fn_attribute_promotion(
  p_code TEXT, p_buyer UUID, p_order UUID, p_kirim UUID,
  p_order_total BIGINT, p_platform_commission BIGINT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE pr public.promotions; v_rate INT; v_cap BIGINT; v_amt BIGINT; v_txn UUID;
BEGIN
  SELECT * INTO pr FROM public.promotions WHERE code = p_code AND is_active;
  IF NOT FOUND THEN RETURN 0; END IF;
  IF pr.promoter_id = p_buyer THEN RAISE EXCEPTION 'SELF_REFERRAL_BLOCKED'; END IF;

  SELECT rate_bps, max_commission_sen INTO v_rate, v_cap
    FROM internal.commission_rules
   WHERE context='promoter' AND effective_to IS NULL
   ORDER BY effective_from DESC LIMIT 1;

  v_amt := LEAST(p_platform_commission * v_rate / 10000, COALESCE(v_cap, 999999999));

  INSERT INTO public.promotion_attributions
    (promotion_id, buyer_id, order_id, kirim_id, order_total_sen,
     platform_commission_sen, promoter_sen)
  VALUES (pr.id, p_buyer, p_order, p_kirim, p_order_total,
          p_platform_commission, v_amt);

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('PROMOTER_COMMISSION','promotion', pr.id,
          'promo:'||COALESCE(p_order,p_kirim)::text, 'Kongsi & Untung')
  RETURNING id INTO v_txn;

  PERFORM internal.fn_post(v_txn,'PLATFORM_COMMISSION','DEBIT', v_amt);
  PERFORM internal.fn_post(v_txn,'PROMOTER_PAYABLE:'||pr.promoter_id,'CREDIT', v_amt);
  RETURN v_amt;
END $$;

/** Expire perishable lots. Unsold stock is the CARRIER's loss — not platform
 *  expense, not escrow. The ledger should say so rather than blur it. */
CREATE OR REPLACE FUNCTION internal.fn_expire_lots()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE l RECORD; v_txn UUID; v_loss BIGINT; n INT := 0;
BEGIN
  FOR l IN SELECT * FROM public.carrier_stock_lots
            WHERE status='ACTIVE' AND sell_by IS NOT NULL AND sell_by < now()
  LOOP
    v_loss := (l.cost_basis_sen * (l.qty_total - l.qty_sold) / l.qty_total)::bigint;
    IF v_loss > 0 THEN
      INSERT INTO internal.ledger_transactions
        (kind, reference_type, reference_id, idempotency_key, description)
      VALUES ('LOT_WRITEDOWN','lot', l.id, 'writedown:'||l.id::text,
              'Unsold stock expired')
      RETURNING id INTO v_txn;
      PERFORM internal.fn_post(v_txn,'CARRIER_LOSS:'||l.carrier_id,'DEBIT', v_loss);
      PERFORM internal.fn_post(v_txn,'CARRIER_INVENTORY:'||l.carrier_id,'CREDIT', v_loss);
    END IF;
    UPDATE public.carrier_stock_lots SET status='EXPIRED' WHERE id = l.id;
    UPDATE public.carriers
       SET inventory_at_risk_sen = GREATEST(0, inventory_at_risk_sen - v_loss)
     WHERE id = l.carrier_id;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- RLS
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.capacity_invites      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invite_responses      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.restock_requests      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promotions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.promotion_attributions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.carrier_stock_lots    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trip_listings         ENABLE ROW LEVEL SECURITY;

CREATE POLICY invites_select ON public.capacity_invites FOR SELECT TO authenticated
  USING (carrier_id = authz.my_carrier_id()
         OR target_user_id = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.community_members cm
                    WHERE cm.community_id = capacity_invites.community_id
                      AND cm.user_id = (SELECT auth.uid()))
         OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.capacity_invites FROM authenticated, anon;

CREATE POLICY invite_resp_own ON public.invite_responses FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY restock_parties ON public.restock_requests FOR SELECT TO authenticated
  USING (supplier_id = (SELECT auth.uid())
         OR carrier_id = authz.my_carrier_id() OR authz.is_admin());

CREATE POLICY promotions_own ON public.promotions FOR SELECT TO authenticated
  USING (promoter_id = (SELECT auth.uid()) OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.promotions FROM authenticated, anon;

CREATE POLICY attributions_own ON public.promotion_attributions FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.promotions p
                 WHERE p.id = promotion_attributions.promotion_id
                   AND p.promoter_id = (SELECT auth.uid()))
         OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.promotion_attributions FROM authenticated, anon;

-- Buyers see ACTIVE lots. cost_basis_sen is hidden by the view, not the policy
-- (FR-447) — a policy filters rows, not columns.
CREATE POLICY lots_select ON public.carrier_stock_lots FOR SELECT TO authenticated
  USING (carrier_id = authz.my_carrier_id() OR authz.is_admin()
         OR (status='ACTIVE' AND (sell_by IS NULL OR sell_by > now())));
CREATE POLICY lots_write ON public.carrier_stock_lots FOR ALL TO authenticated
  USING (carrier_id = authz.my_carrier_id())
  WITH CHECK (carrier_id = authz.my_carrier_id());

CREATE VIEW public.v_lot_listings WITH (security_barrier=true) AS
  SELECT l.id, l.carrier_id, l.seller_id, l.trip_id, l.title, l.category_id,
         l.handling_flags, l.unit, l.price_per_unit_sen, l.photo_paths,
         l.sell_by, l.status,
         (l.qty_total - l.qty_reserved - l.qty_sold) AS qty_available
  FROM public.carrier_stock_lots l
  WHERE l.status = 'ACTIVE' AND (l.sell_by IS NULL OR l.sell_by > now());
GRANT SELECT ON public.v_lot_listings TO authenticated;

CREATE POLICY listings_select ON public.trip_listings FOR SELECT TO authenticated
  USING (is_active OR authz.is_admin());

GRANT EXECUTE ON FUNCTION
  public.rpc_send_capacity_invite(UUID,TEXT,UUID,UUID,TEXT),
  public.rpc_buy_from_lot(UUID,NUMERIC,TEXT)
TO authenticated;

-- ── Feature flags ───────────────────────────────────────────────────────────
-- Ajak Kirim on. Muatan Jual stays OFF until LGL-02/13/14/15 are answered:
-- the schema is ready, the business is not.
UPDATE ref.app_config
   SET value = '{"marketplace":false,"prepaid_payments":false,"agent_hubs":false,
                 "ajak_kirim":true,"kongsi_untung":false,"muatan_jual":false}'::jsonb
 WHERE key = 'feature_flags';

INSERT INTO ref.app_config (key, value, description) VALUES
  ('lot_max_value_sen','20000','R-1: RM200 ceiling per lot at launch'),
  ('lot_min_completed_deliveries','20','R-1: history required before selling'),
  ('invite_max_per_recipient_hours','24','FR-404')
ON CONFLICT (key) DO NOTHING;

-- ════════════════════════════════════════════════════════════════════════════
-- Audit fixes (GAP-REPORT.md D-1, D-2)
-- Both tables have RLS enabled by the blanket loop in 0003 but no policy, so
-- default-deny locks out their legitimate owners. Neither is a security hole;
-- both present as a mysteriously empty screen.
-- ════════════════════════════════════════════════════════════════════════════

-- D-1: a seller must be able to read their own stock movement log.
CREATE POLICY inventory_moves_own ON public.inventory_movements
  FOR SELECT TO authenticated
  USING (
    product_id IN (
      SELECT p.id FROM public.products p
      JOIN public.sellers s ON s.id = p.seller_id
      WHERE s.user_id = (SELECT auth.uid()))
    OR authz.is_admin());
-- Writes stay closed: movements are append-only via internal.fn_adjust_inventory.
REVOKE INSERT, UPDATE, DELETE ON public.inventory_movements FROM authenticated, anon;

-- D-2: a user must be able to see their own roles. Currently masked because
-- roles arrive in the JWT claim, but any admin or debug surface reading the
-- table would silently return nothing.
CREATE POLICY user_roles_own ON public.user_roles
  FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.user_roles FROM authenticated, anon;
