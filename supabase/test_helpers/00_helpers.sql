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
CREATE OR REPLACE FUNCTION tests.authenticate_as(p_handle TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE v_id UUID; v_roles TEXT[]; v_carrier UUID; v_seller UUID;
BEGIN
  v_id := tests.uid(p_handle);
  IF v_id IS NULL THEN RAISE EXCEPTION 'no such test user: %', p_handle; END IF;
  SELECT array_agg(role::text) INTO v_roles
    FROM public.user_roles WHERE user_id=v_id AND revoked_at IS NULL;
  SELECT id INTO v_carrier FROM public.carriers WHERE user_id=v_id;
  SELECT id INTO v_seller  FROM public.sellers  WHERE user_id=v_id;

  PERFORM set_config('role','authenticated',true);
  PERFORM set_config('request.jwt.claims', json_build_object(
    'sub', v_id::text, 'role','authenticated',
    'app_metadata', json_build_object(
      'roles', COALESCE(v_roles, ARRAY[]::text[]),
      'carrier_id', v_carrier, 'seller_id', v_seller,
      'account_status','active')
  )::text, true);
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
-- ============================================================================
GRANT USAGE ON SCHEMA tests TO authenticated, anon;
GRANT SELECT ON tests.handles TO authenticated, anon;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA tests TO authenticated, anon;

-- Functions created after this point inherit the same grant, so a future
-- helper cannot silently reintroduce the permission-denied failure.
ALTER DEFAULT PRIVILEGES IN SCHEMA tests
  GRANT EXECUTE ON FUNCTIONS TO authenticated, anon;
