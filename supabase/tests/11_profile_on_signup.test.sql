-- ============================================================================
-- 0015_profile_on_auth_signup.sql regression tests.
--
-- Exercises the ACTUAL migration's trigger (tg_auth_users_create_profile)
-- and the phone-nullability relaxation it depends on, against a real
-- auth.users INSERT shaped exactly like the app's own email/password signup
-- (AuthRepositoryImpl.signUpWithEmail -- email + password only, no phone, no
-- custom claims) -- not a stand-in for it.
-- ============================================================================
BEGIN;
SELECT plan(14);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();

-- A new email/password signup, exactly as AuthRepositoryImpl.signUpWithEmail
-- produces it.
DO $$
DECLARE v_new_user UUID := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    created_at, updated_at)
  VALUES (
    v_new_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'newsignup@example.com', crypt('Test12345!', gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
    '', '', '', '',
    now(), now());
  INSERT INTO tests.handles (handle, user_id) VALUES ('_newsignup', v_new_user)
    ON CONFLICT (handle) DO UPDATE SET user_id = EXCLUDED.user_id;
END $$;

-- A. Exactly one profile row was created for the new user.
SELECT is(
  (SELECT count(*)::int FROM public.profiles WHERE id = tests.uid('_newsignup')),
  1, 'exactly one profiles row exists for the new signup');

-- B. That row's id is the same auth.users id, not a generated/mismatched one.
SELECT is(
  (SELECT id FROM public.profiles WHERE id = tests.uid('_newsignup')),
  tests.uid('_newsignup'), 'profiles.id matches auth.users.id exactly');

-- C. Default role is the safe default: no role rows at all. (The client's
-- own AuthUser.primaryRole fallback -- see AuthRoleResolutionTest -- treats
-- an empty roles array as CUSTOMER; the server-side contract this depends on
-- is that signup creates no user_roles row.)
SELECT is(
  (SELECT count(*)::int FROM public.user_roles WHERE user_id = tests.uid('_newsignup')),
  0, 'no user_roles row was created for a new signup');

-- D. A different authenticated user cannot create a profile for someone else
-- -- there is no INSERT policy on profiles for `authenticated` at all, so
-- RLS refuses the statement outright regardless of the id supplied.
SELECT tests.authenticate_as('aisyah');
SELECT throws_ok(
  format($$INSERT INTO public.profiles (id, phone, status)
           VALUES (%L, '+60199999999', 'active')$$, gen_random_uuid()),
  '42501', NULL, 'authenticated client cannot INSERT into profiles at all');
SELECT tests.clear_auth();

-- E. Signing up cannot self-assign carrier/seller: custom_access_token_hook,
-- called for the freshly-created user, returns empty roles and a null
-- carrier_id -- the same function the real Supabase Auth Hook invokes at
-- token-mint time, not a stand-in.
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', tests.uid('_newsignup'),
       'claims', jsonb_build_object('sub', tests.uid('_newsignup')))
   )->'claims'->'app_metadata'->'roles'),
  '[]'::jsonb,
  'hook reports empty roles for a brand-new signup, not carrier/seller');

SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', tests.uid('_newsignup'),
       'claims', jsonb_build_object('sub', tests.uid('_newsignup')))
   )->'claims'->'app_metadata'->'carrier_id'),
  'null'::jsonb,
  'hook reports null carrier_id for a brand-new signup');

-- F. Existing users are not duplicated or corrupted: re-running the
-- trigger's own insert statement for an id that already has a profile is a
-- safe no-op (ON CONFLICT DO NOTHING), and the pre-existing fixture row
-- (aisyah, created by tests.seed_fixture before this file's signup) is
-- untouched.
SELECT lives_ok(
  format($$INSERT INTO public.profiles (id, phone, status)
           VALUES (%L, NULL, 'pending') ON CONFLICT (id) DO NOTHING$$,
         tests.uid('aisyah')),
  're-inserting an existing id is a safe no-op (ON CONFLICT DO NOTHING)');
SELECT is(
  (SELECT count(*)::int FROM public.profiles WHERE id = tests.uid('aisyah')),
  1, 'the pre-existing fixture profile was not duplicated');
SELECT is(
  (SELECT status FROM public.profiles WHERE id = tests.uid('aisyah')),
  'active', 'the pre-existing fixture profile was not overwritten to pending');

-- G. Existing carrier profiles continue to work: rahman (carrier, from the
-- fixture) still resolves a real carrier_id through the hook post-migration.
SELECT isnt(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', tests.uid('rahman'),
       'claims', jsonb_build_object('sub', tests.uid('rahman')))
   )->'claims'->'app_metadata'->>'carrier_id'),
  NULL,
  'an existing carrier fixture still resolves a real carrier_id post-migration');

-- H. JWT role resolution works end-to-end for the newly-created profile once
-- a role is granted the normal way (mirrors how an admin would actually
-- promote someone -- never signup itself). This also proves the FK from
-- user_roles.user_id to profiles(id) resolves for a signup-created row.
SELECT lives_ok(
  format($$INSERT INTO public.user_roles (user_id, role) VALUES (%L, 'customer')$$,
         tests.uid('_newsignup')),
  'granting a role to the new profile succeeds (FK to profiles(id) resolves)');
SELECT is(
  (public.custom_access_token_hook(
     jsonb_build_object('user_id', tests.uid('_newsignup'),
       'claims', jsonb_build_object('sub', tests.uid('_newsignup')))
   )->'claims'->'app_metadata'->'roles'),
  '["customer"]'::jsonb,
  'hook reflects the granted role for the now-profiled user');

-- I. RLS remains enforced on the signup-created row: the new user can read
-- their own profile...
SELECT tests.authenticate_as('_newsignup');
SELECT is(
  (SELECT count(*)::int FROM public.profiles WHERE id = tests.uid('_newsignup')),
  1, 'the new user can read their own profile under RLS');
-- ...but not anyone else's.
SELECT is(
  (SELECT count(*)::int FROM public.profiles WHERE id = tests.uid('aisyah')),
  0, 'the new user cannot read another profile under RLS');
SELECT tests.clear_auth();

SELECT * FROM finish();
ROLLBACK;
