-- ============================================================================
-- Compliance gates (0007). Muatan Jual is BUILT and GATED, not deleted —
-- these assert the gate holds, and that it can be opened deliberately.
-- ============================================================================
BEGIN;
SELECT plan(11);
SELECT tests.clear_auth();      -- deterministic role: start as postgres
SELECT tests.seed_fixture();
SELECT tests.clear_auth();

-- ── Gate is shut by default ────────────────────────────────────────────────
SELECT is((SELECT status::text FROM ref.compliance_state WHERE id),
  'NOT_READY', 'compliance_status starts NOT_READY');

SELECT is((SELECT count(*) FROM ref.feature_gates
           WHERE key LIKE 'muatan_jual%' AND enabled), 0::bigint,
  'all four Muatan Jual gates start closed');

SELECT throws_ok($$SELECT internal.fn_marketplace_gate()$$,
  NULL, NULL, 'marketplace gate blocks while compliance_status is NOT_READY');

-- ── The gate can be opened deliberately — it is not a dead feature ─────────
UPDATE ref.compliance_state SET status='PRODUCTION_ACTIVE' WHERE id;
UPDATE ref.feature_gates SET enabled=true WHERE key='muatan_jual_enabled';

SELECT lives_ok($$SELECT internal.fn_marketplace_gate()$$,
  'gate opens when compliance_status=PRODUCTION_ACTIVE and master flag is on');

-- ...but checkout is a SEPARATE gate. Onboarding can open before money does.
SELECT throws_ok($$SELECT internal.fn_marketplace_gate(NULL,NULL,true)$$,
  NULL, NULL, 'checkout stays blocked by its own independent gate');

-- ── Category controls ──────────────────────────────────────────────────────
SELECT throws_ok(
  format($$SELECT internal.fn_marketplace_gate(%L)$$,
         (SELECT id FROM ref.categories WHERE slug='hasil-laut')),
  NULL, NULL, 'a category that is not marketplace_enabled is refused');

-- A prohibited category can never be enabled, whatever an admin clicks.
SELECT throws_ok($$
  UPDATE ref.category_compliance
     SET legal_status='PROHIBITED', marketplace_enabled=true
   WHERE category_id=(SELECT id FROM ref.categories WHERE slug='kraf')$$,
  '23514', NULL, 'ck_prohibited_not_enabled blocks enabling a prohibited category');

-- ── Seller licence expiry blocks sales (§8) ────────────────────────────────
DO $$
DECLARE v_seller UUID; v_cat UUID;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug='hasil-laut';
  INSERT INTO public.sellers (user_id,business_name,community_id,status,onboarding_status)
  VALUES (tests.uid('rahman'),'Ikan Segar Beluran',
          (SELECT id FROM public.communities LIMIT 1),'APPROVED','ACTIVE')
  RETURNING id INTO v_seller;
  INSERT INTO tests.handles (handle,user_id) VALUES ('_seller',v_seller)
  ON CONFLICT (handle) DO UPDATE SET user_id=EXCLUDED.user_id;

  UPDATE ref.category_compliance SET marketplace_enabled=true, legal_status='LICENCE_REQUIRED',
         requires_licence=true, licence_type='Fisheries'
   WHERE category_id=v_cat;

  INSERT INTO public.seller_licences (seller_id,category_id,licence_no,licence_type,
    issuing_authority,issue_date,expiry_date,document_path,verification_status)
  VALUES (v_seller,v_cat,'FSH-001','Fisheries','Sabah Fisheries',
          current_date - 400, current_date - 1, 'lic.jpg','VERIFIED');
END $$;

SELECT throws_ok(
  format($$SELECT internal.fn_marketplace_gate(%L,%L)$$,
         (SELECT id FROM ref.categories WHERE slug='hasil-laut'), tests.uid('_seller')),
  NULL, NULL, 'an expired licence blocks sales automatically');

SELECT is(internal.fn_expire_seller_licences(), 1,
  'expiry job marks the lapsed licence EXPIRED');

-- ── Geography is configuration, not architecture (§22) ─────────────────────
SELECT ok((SELECT count(*) FROM ref.districts) >= 10,
  'Sabah districts seeded beyond the pilot corridor');

SELECT is((SELECT count(*) FROM public.service_areas WHERE status='PILOT'), 3::bigint,
  'Beluran, Paitan and KK are the active pilot areas; the rest are PLANNED');

SELECT * FROM finish();
ROLLBACK;
