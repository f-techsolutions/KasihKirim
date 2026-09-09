-- ============================================================================
-- Test helpers — INSTALLED SEPARATELY, NOT RUN AS A TAP SUITE.
--
-- This file lives in supabase/tests/helpers/ rather than supabase/tests/ so
-- that pg_prove's non-recursive `tests/*.sql` glob does not pick it up. It has
-- no TAP plan and is not a test; when it sat alongside the suites, pg_prove
-- reported it as a file with "no plan".
--
-- Install it once, after `supabase db reset` and before `supabase test db`:
--     psql "$DB_URL" -f supabase/tests/helpers/00_helpers.sql
-- See docs/DEVELOPMENT-ENVIRONMENT.md §2d.
--
-- Everything here is TEST-ONLY. Schema `tests` is created by this file and by
-- no migration, so it does not exist in staging or production. The grants at
-- the foot of this file therefore touch nothing a real deployment has.
-- ============================================================================
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS tests;

/** Create an auth user + profile without going through the auth API. */
CREATE OR REPLACE FUNCTION tests.create_user(
  p_handle TEXT, p_phone TEXT, p_roles TEXT[] DEFAULT ARRAY['customer'])
RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE v_id UUID := gen_random_uuid(); r TEXT;
BEGIN
  -- GoTrue's schema is fussy: several token columns are NOT NULL DEFAULT ''.
  -- Supplying them explicitly keeps this working across GoTrue versions.
  INSERT INTO auth.users (
    id, instance_id, aud, role, phone, phone_confirmed_at,
    encrypted_password, raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    created_at, updated_at)
  VALUES (
    v_id, '00000000-0000-0000-0000-000000000000','authenticated','authenticated',
    p_phone, now(), '', '{"provider":"phone","providers":["phone"]}'::jsonb, '{}'::jsonb,
    '', '', '', '',
    now(), now());
  -- 0015_profile_on_auth_signup.sql's tg_auth_users_create_profile trigger
  -- now fires on the auth.users insert above and creates a placeholder
  -- profiles row (status 'pending', phone NULL) before this statement runs.
  --
  -- An UPSERT (ON CONFLICT DO UPDATE) is the wrong fix here, even though it
  -- looks right: internal.tg_protect_profile_columns is a BEFORE UPDATE
  -- trigger (0003_functions_rls.sql) that forces status/phone/rating_*/
  -- nric_hash back to OLD for anyone who isn't authz.is_admin() -- which is
  -- everyone here, since this runs with no JWT/request context at all. An
  -- upsert's UPDATE branch goes straight through that trigger and gets
  -- silently neutered: confirmed live -- status and phone stayed at the
  -- trigger's placeholder values while unprotected columns (display_name)
  -- went through fine, exactly the split PROTECTED/unprotected column list
  -- predicts, and exactly what broke 02_rls.test.sql's "public projection"
  -- count and this file's own status assertion in CI.
  --
  -- DELETE + a fresh INSERT never touches UPDATE, so the protection trigger
  -- never fires, and this ends up with the exact row this function has
  -- always promised (status 'active', not the placeholder 'pending').
  DELETE FROM public.profiles WHERE id = v_id;
  INSERT INTO public.profiles (id, phone, display_name, status)
  VALUES (v_id, p_phone, p_handle, 'active');
  FOREACH r IN ARRAY p_roles LOOP
    INSERT INTO public.user_roles (user_id, role) VALUES (v_id, r::ref.user_role);
  END LOOP;
  INSERT INTO tests.handles (handle, user_id) VALUES (p_handle, v_id);
  RETURN v_id;
END $$;

CREATE TABLE IF NOT EXISTS tests.handles (handle TEXT PRIMARY KEY, user_id UUID);

CREATE OR REPLACE FUNCTION tests.uid(p_handle TEXT) RETURNS UUID
LANGUAGE sql STABLE AS $$ SELECT user_id FROM tests.handles WHERE handle=p_handle $$;

/** Simulate a PostgREST request from this user, with their real role claims. */
CREATE OR REPLACE FUNCTION tests.get_user_context(p_handle TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, tests, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', h.user_id,
    'roles',
      COALESCE(
        (
          SELECT jsonb_agg(ur.role::text ORDER BY ur.role::text)
          FROM public.user_roles ur
          WHERE ur.user_id = h.user_id
            AND ur.revoked_at IS NULL
        ),
        '[]'::jsonb
      ),
    'carrier_id',
      (
        SELECT c.id
        FROM public.carriers c
        WHERE c.user_id = h.user_id
        LIMIT 1
      ),
    'seller_id',
      (
        SELECT se.id
        FROM public.sellers se
        WHERE se.user_id = h.user_id
        LIMIT 1
      )
  )
  FROM tests.handles h
  WHERE h.handle = p_handle
$$;

CREATE OR REPLACE FUNCTION tests.get_user_context(p_handle TEXT)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, tests, pg_temp
AS $$
  SELECT jsonb_build_object(
    'id', h.user_id,
    'roles',
      COALESCE(
        (
          SELECT jsonb_agg(ur.role::text ORDER BY ur.role::text)
          FROM public.user_roles ur
          WHERE ur.user_id = h.user_id
            AND ur.revoked_at IS NULL
        ),
        '[]'::jsonb
      ),
    'carrier_id',
      (
        SELECT c.id
        FROM public.carriers c
        WHERE c.user_id = h.user_id
        LIMIT 1
      ),
    'seller_id',
      (
        SELECT se.id
        FROM public.sellers se
        WHERE se.user_id = h.user_id
        LIMIT 1
      )
  )
  FROM tests.handles h
  WHERE h.handle = p_handle
$$;

CREATE OR REPLACE FUNCTION tests.authenticate_as(p_handle TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
  v_ctx JSONB;
  v_id UUID;
  v_roles TEXT[];
  v_carrier UUID;
  v_seller UUID;
BEGIN
  v_ctx := tests.get_user_context(p_handle);

  IF v_ctx IS NULL THEN
    RAISE EXCEPTION 'no such test user: %', p_handle;
  END IF;

  v_id := (v_ctx->>'id')::UUID;

  SELECT COALESCE(
    ARRAY(
      SELECT jsonb_array_elements_text(v_ctx->'roles')
    ),
    ARRAY[]::TEXT[]
  )
  INTO v_roles;

  v_carrier := NULLIF(v_ctx->>'carrier_id','')::UUID;
  v_seller  := NULLIF(v_ctx->>'seller_id','')::UUID;

  PERFORM set_config('role', 'authenticated', true);

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object(
      'sub', v_id::text,
      'role', 'authenticated',
      'app_metadata', json_build_object(
        'roles', v_roles,
        'carrier_id', v_carrier,
        'seller_id', v_seller,
        'account_status', 'active'
      )
    )::text,
    true
  );
END $$;

CREATE OR REPLACE FUNCTION tests.clear_auth() RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('role','postgres',true);
  PERFORM set_config('request.jwt.claims','',true);
END $$;

/** Minimal fixture: one carrier with a trip on the Beluran corridor, and one
 *  BELI kirim with an RM35 budget cap. Mirrors the deck's worked example. */
CREATE OR REPLACE FUNCTION tests.seed_fixture() RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
  v_aisyah UUID; v_rahman UUID; v_carrier UUID; v_vehicle UUID; v_trip UUID;
  v_beluran UUID; v_kk UUID; v_kepayan UUID; v_addr UUID; v_cat UUID; v_kirim UUID;
BEGIN
  PERFORM tests.clear_auth();
  v_aisyah := tests.create_user('aisyah','+60128880001', ARRAY['customer']);
  v_rahman := tests.create_user('rahman','+60128880002', ARRAY['customer','carrier']);
  PERFORM tests.create_user('admin','+60128880003', ARRAY['admin_ops']);
  PERFORM tests.create_user('stranger','+60128880004', ARRAY['customer']);

  SELECT id INTO v_beluran FROM ref.route_nodes WHERE name='Beluran';
  SELECT id INTO v_kk      FROM ref.route_nodes WHERE name='Kota Kinabalu';
  SELECT id INTO v_cat     FROM ref.categories  WHERE slug='hasil-laut';
  SELECT id INTO v_kepayan FROM public.communities WHERE name='Kg Kepayan Baru';

  INSERT INTO public.carriers (user_id,status,verified_at,float_limit_sen)
  VALUES (v_rahman,'APPROVED',now(),50000) RETURNING id INTO v_carrier;

  INSERT INTO public.vehicles (carrier_id,vehicle_type,plate_no,
    capacity_weight_grams,capacity_volume_cm3,capacity_parcels,is_verified)
  VALUES (v_carrier,'PICKUP','SAB1234',50000,500000,8,true) RETURNING id INTO v_vehicle;

  INSERT INTO public.trips (carrier_id,vehicle_id,status,origin_node_id,dest_node_id,
    corridor_nodes,depart_at,capacity_weight_grams,capacity_volume_cm3,capacity_parcels)
  VALUES (v_carrier,v_vehicle,'BOARDING',v_beluran,v_kk,
    ARRAY[v_beluran,v_kk], now()+interval '1 day', 10000, 500000, 5)
  RETURNING id INTO v_trip;

  INSERT INTO public.addresses (user_id,label,recipient_name,recipient_phone,
    community_id,landmark_note,nearest_node_id)
  VALUES (v_aisyah,'Rumah','Aisyah','+60128880001',v_kepayan,
    'Rumah biru selepas SK Kepayan',v_kk) RETURNING id INTO v_addr;

  INSERT INTO public.kirim_requests (reference_code,requester_id,kirim_type,status,
    item_description,category_id,est_weight_grams,budget_cap_sen,
    dest_address_id,origin_node_id,dest_node_id,handling_flags,total_escrow_sen)
  VALUES ('KK-TEST01',v_aisyah,'BELI','POSTED',
    'Udang galah saiz sederhana, 2kg',v_cat,2000,3500,
    v_addr,v_beluran,v_kk,'{PERISHABLE,COLD_CHAIN}',5000)
  RETURNING id INTO v_kirim;

  INSERT INTO tests.handles (handle,user_id) VALUES
    ('_trip',v_trip),('_kirim',v_kirim),('_carrier',v_carrier),('_addr',v_addr)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;
END $$;


-- ============================================================================
-- TEST-ONLY GRANTS
--
-- tests.authenticate_as() switches the session to `authenticated` for the rest
-- of the transaction, which is the point: RLS must be exercised as a real user.
-- But `authenticated` then has no rights on schema `tests`, so any later
-- tests.uid() call failed with "permission denied for schema tests".
--
-- Granting here is safe and isolated:
--   * schema `tests` is created by this file, never by a migration;
--   * it does not exist in staging or production;
--   * nothing is granted on any production schema, table or function.
--
-- INSERT/UPDATE (not just SELECT): a test that calls tests.authenticate_as()
-- and then registers a handle for whatever it just created via a real
-- SECURITY DEFINER RPC call -- the only way to get a fixture that a
-- function reading auth.uid() will actually accept -- needs to write to
-- tests.handles from inside that same authenticated session, not just read
-- it back afterwards.
-- ============================================================================
GRANT USAGE ON SCHEMA tests TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE ON tests.handles TO authenticated, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA tests TO authenticated, anon;

-- Functions created after this point inherit the same grant, so a future
-- helper cannot silently reintroduce the permission-denied failure.
ALTER DEFAULT PRIVILEGES IN SCHEMA tests
  GRANT EXECUTE ON FUNCTIONS TO authenticated, anon;
