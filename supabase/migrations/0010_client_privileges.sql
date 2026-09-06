-- ============================================================================
-- KasihKirim — 0010_client_privileges.sql
--
-- DEFECT: no migration ever granted table privileges to `authenticated`.
-- The first real RLS test surfaced it:
--     ERROR: permission denied for table deliveries
--     ERROR: permission denied for table user_roles
--
-- RLS filters ROWS. It does not grant ACCESS. A role with no table privilege
-- is refused at the privilege check, before any policy is evaluated -- so this
-- was not a test artefact: every authenticated client read would have failed
-- in production too.
--
-- The grants below are DERIVED FROM THE POLICIES, not chosen by hand: a table
-- receives exactly the privileges for which an `authenticated` policy already
-- exists, and nothing more. RLS continues to decide which rows are visible.
--
--   policy FOR SELECT           -> GRANT SELECT
--   policy FOR ALL              -> GRANT SELECT, INSERT, UPDATE, DELETE
--   no authenticated policy     -> NO GRANT  (default deny stands)
--
-- Deliberately absent, and they must stay absent:
--   public.handover_codes    REVOKE ALL  (0003) -- codes readable by nobody
--   internal.*  audit.*                          -- not PostgREST-exposed
--   public.trips.reserved_*  column grants (0009) -- capacity integrity
--   public.deliveries INSERT/UPDATE/DELETE (0001) -- server-owned state machine
-- ============================================================================

GRANT DELETE,INSERT,SELECT,UPDATE  ON public.addresses TO authenticated;
GRANT SELECT                       ON public.agents TO authenticated;
GRANT SELECT                       ON public.capacity_invites TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.carrier_stock_lots TO authenticated;
GRANT SELECT                       ON public.carriers TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.cart_items TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.carts TO authenticated;
GRANT SELECT                       ON public.communities TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.community_members TO authenticated;
GRANT SELECT                       ON public.conversation_participants TO authenticated;
GRANT SELECT                       ON public.conversations TO authenticated;
GRANT SELECT                       ON public.deliveries TO authenticated;
GRANT SELECT                       ON public.delivery_events TO authenticated;
GRANT SELECT                       ON public.delivery_offers TO authenticated;
GRANT SELECT                       ON public.delivery_tracking_points TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.devices TO authenticated;
GRANT SELECT                       ON public.disputes TO authenticated;
GRANT SELECT                       ON public.inventory TO authenticated;
GRANT SELECT                       ON public.inventory_movements TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.invite_responses TO authenticated;
GRANT INSERT,SELECT,UPDATE         ON public.kirim_requests TO authenticated;
GRANT INSERT,SELECT                ON public.messages TO authenticated;
GRANT SELECT,UPDATE                ON public.notifications TO authenticated;
GRANT SELECT                       ON public.order_items TO authenticated;
GRANT SELECT                       ON public.orders TO authenticated;
GRANT SELECT                       ON public.pickup_points TO authenticated;
GRANT SELECT                       ON public.price_variances TO authenticated;
GRANT SELECT                       ON public.product_images TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.products TO authenticated;
GRANT SELECT,UPDATE                ON public.profiles TO authenticated;
GRANT SELECT                       ON public.promotion_attributions TO authenticated;
GRANT SELECT                       ON public.promotions TO authenticated;
GRANT SELECT                       ON public.proofs TO authenticated;
GRANT SELECT                       ON public.restock_requests TO authenticated;
GRANT INSERT,SELECT                ON public.reviews TO authenticated;
GRANT SELECT                       ON public.seller_categories TO authenticated;
GRANT INSERT,SELECT                ON public.seller_documents TO authenticated;
GRANT INSERT,SELECT                ON public.seller_licences TO authenticated;
GRANT SELECT                       ON public.sellers TO authenticated;
GRANT SELECT                       ON public.service_areas TO authenticated;
GRANT SELECT                       ON public.trip_listings TO authenticated;
GRANT SELECT                       ON public.trip_reservations TO authenticated;
GRANT INSERT,SELECT,UPDATE         ON public.trips TO authenticated;
GRANT SELECT                       ON public.user_badges TO authenticated;
GRANT SELECT                       ON public.user_roles TO authenticated;
GRANT DELETE,INSERT,SELECT,UPDATE  ON public.vehicles TO authenticated;
GRANT SELECT                       ON public.voucher_campaigns TO authenticated;
GRANT SELECT                       ON public.voucher_issuances TO authenticated;

-- ── anon gets nothing ───────────────────────────────────────────────────────
-- Every policy in this schema is TO authenticated. An unauthenticated caller
-- has no business reading any of it.
--
-- Scoped to tables WE own. `REVOKE ... ON ALL TABLES IN SCHEMA public` also
-- targets PostGIS's spatial_ref_sys, which the extension owns, producing:
--     WARNING 01006: no privileges could be revoked for "spatial_ref_sys"
-- Those warnings were harmless -- the revoke simply had no effect on an object
-- we do not own -- but they are noise that hides real warnings, and attempting
-- to alter extension-owned objects is not something a migration should do.
DO $revoke_anon$
DECLARE t RECORD;
BEGIN
  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'e'
    WHERE n.nspname = 'public' AND c.relkind IN ('r','v')
      AND d.objid IS NULL                       -- not extension-owned
  LOOP
    EXECUTE format('REVOKE ALL ON public.%I FROM anon', t.relname);
  END LOOP;
END $revoke_anon$;

-- ── Re-assert the narrower rules that must survive the grants above ─────────
-- Order matters: these REVOKEs run after the GRANTs so they win.
REVOKE INSERT, UPDATE, DELETE ON public.deliveries              FROM authenticated;
REVOKE UPDATE, DELETE         ON public.delivery_events         FROM authenticated;
REVOKE UPDATE, DELETE         ON public.delivery_tracking_points FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.delivery_offers         FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.user_roles              FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.capacity_invites        FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.promotions              FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.promotion_attributions  FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.inventory_movements     FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.seller_categories       FROM authenticated;
REVOKE UPDATE, DELETE         ON public.seller_licences         FROM authenticated;
REVOKE ALL                    ON public.handover_codes          FROM authenticated, anon;

-- trips: table-wide UPDATE is replaced by the column grant from 0009, so that
-- reserved_* and capacity_* remain unreachable.
REVOKE UPDATE ON public.trips FROM authenticated;
GRANT  UPDATE (status, depart_at, depart_window_minutes, arrive_est_at,
               corridor_nodes, accepts_cod, accepts_beli, recurring_rule,
               handling_capabilities, vehicle_id, updated_at)
  ON public.trips TO authenticated;

-- Reference data: read-only.
-- ref contains no extension-owned objects, so the blanket form is safe here.
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ref FROM authenticated, anon;
REVOKE ALL ON ALL TABLES IN SCHEMA ref FROM anon;
