-- ============================================================================
-- KasihKirim — 0000_prelude.sql
--
-- MUST run first. Postgres resolves functions referenced in RLS policies at
-- policy-creation time, so every auth helper has to exist before any migration
-- creates a policy that calls it. This file exists solely to guarantee that.
-- ============================================================================

-- ── Extensions ──────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- pg_cron only installs on the database it is configured for. On a local stack
-- that is often not the app database, so failure here must not abort the run.
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron unavailable (%). Scheduled jobs will be skipped.', SQLERRM;
END $$;

-- ── uuidv7 shim (native from PG18) ──────────────────────────────────────────
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') THEN
    EXECUTE $f$
      CREATE FUNCTION public.uuidv7() RETURNS uuid LANGUAGE sql VOLATILE AS $b$
        SELECT encode(
          set_bit(set_bit(overlay(
            uuid_send(gen_random_uuid())
            PLACING substring(int8send(
              floor(extract(epoch FROM clock_timestamp())*1000)::bigint) FROM 3)
            FROM 1 FOR 6),
          52,1),53,1),'hex')::uuid;
      $b$;
    $f$;
  END IF;
END $$;

-- ── Schemas ─────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS internal;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS ref;

REVOKE ALL ON SCHEMA internal FROM anon, authenticated;
REVOKE ALL ON SCHEMA audit    FROM anon, authenticated;
GRANT  USAGE ON SCHEMA ref    TO authenticated;

-- Reminder: supabase/config.toml exposes ONLY ["public","graphql_public"].
-- internal/audit/ref are unreachable through PostgREST regardless of policy.

-- ── Auth helpers ────────────────────────────────────────────────────────────
-- STABLE so the planner evaluates them once per statement, not once per row.
-- All read the JWT claim; none join a table. This is what keeps board queries
-- from degrading into a per-row subquery. See SECURITY.md §4.

CREATE OR REPLACE FUNCTION auth.user_roles() RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(ARRAY(SELECT jsonb_array_elements_text(
    NULLIF(current_setting('request.jwt.claims', true), '')::jsonb
      -> 'app_metadata' -> 'roles')), '{}');
$$;

CREATE OR REPLACE FUNCTION auth.has_role(p text) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT p = ANY(auth.user_roles()); $$;

CREATE OR REPLACE FUNCTION auth.is_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM unnest(auth.user_roles()) r WHERE r LIKE 'admin\_%');
$$;

CREATE OR REPLACE FUNCTION auth.my_carrier_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb
    -> 'app_metadata' ->> 'carrier_id', '')::uuid;
$$;

CREATE OR REPLACE FUNCTION auth.my_seller_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb
    -> 'app_metadata' ->> 'seller_id', '')::uuid;
$$;

GRANT EXECUTE ON FUNCTION
  auth.user_roles(), auth.has_role(text), auth.is_admin(),
  auth.my_carrier_id(), auth.my_seller_id()
TO authenticated, anon, service_role;

-- ── Shared touch trigger ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION internal.tg_touch()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

-- ── Sequence for the partitioned delivery_events table ──────────────────────
-- Identity columns on partitioned tables need PG17+. A plain sequence with a
-- DEFAULT works on every supported version and behaves identically here.
CREATE SEQUENCE IF NOT EXISTS public.delivery_events_seq;
