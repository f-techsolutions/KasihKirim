-- ============================================================================
-- KasihKirim — 0021_badge_definitions_view.sql
--
-- ref.badge_definitions (0001_schema.sql) is not PostgREST-exposed -- ref
-- never is (supabase/config.toml), same reason ref.categories isn't, which
-- is why KirimCategory.kt hardcodes that small closed set client-side
-- instead of reading it. Badges can't take the same shortcut: the client
-- needs to resolve an existing user_badges.badge_id (a server-generated
-- uuidv7, unknown at build time) back to a slug/name/icon to render it,
-- not just send a slug at write time -- there is no write path here at all.
--
-- A read-only view is the same bridge public.v_lot_listings (0006) already
-- uses for exposing ref-adjacent data through PostgREST. No embedding is
-- assumed on the Android side (views do not reliably carry FK metadata for
-- PostgREST's embed inference) -- the client fetches this table and
-- user_badges separately and joins by id client-side.
-- ============================================================================
CREATE OR REPLACE VIEW public.v_badge_definitions WITH (security_barrier=true) AS
  SELECT id, slug, name_ms, name_en, icon, sort_order FROM ref.badge_definitions;

GRANT SELECT ON public.v_badge_definitions TO authenticated;
