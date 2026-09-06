-- ============================================================================
-- Audit fixes D-1 / D-2 (split from 06_commerce.test.sql: one TAP plan per
-- file, so test numbering stays monotonic and unique).
-- ============================================================================
BEGIN;
SELECT plan(4);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();

SELECT tests.authenticate_as('aisyah');

-- D-2: own roles visible, others' not.
SELECT ok((SELECT count(*) FROM public.user_roles
           WHERE user_id = tests.uid('aisyah')) >= 1,
  'D-2: a user can read their own roles');

SELECT is((SELECT count(*) FROM public.user_roles
           WHERE user_id <> tests.uid('aisyah')), 0::bigint,
  'D-2: a user cannot read anyone else roles');

SELECT throws_ok(
  format($$INSERT INTO public.user_roles (user_id, role)
           VALUES (%L,'admin_super')$$, tests.uid('aisyah')),
  '42501', NULL,
  'D-2: a user cannot grant themselves a role');

-- D-1: not a seller, so no movements visible.
SELECT is((SELECT count(*) FROM public.inventory_movements), 0::bigint,
  'D-1: a non-seller sees no inventory movements');

SELECT * FROM finish();
ROLLBACK;
