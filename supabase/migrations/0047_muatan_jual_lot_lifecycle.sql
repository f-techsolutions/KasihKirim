-- ============================================================================
-- KasihKirim — 0047_muatan_jual_lot_lifecycle.sql
--
-- Phase 3 (Muatan Jual): closes the gap between "the schema and the gate
-- exist" (0006/0007/0013) and "a carrier can actually create one" -- there
-- was never a lot-creation RPC at all, and the master gate stays
-- ref.compliance_state.status = 'NOT_READY' regardless of anything here
-- (a legal/business decision, unchanged by this migration).
--
-- Two things found by reading the live schema rather than assuming it was
-- already safe:
--
--   1. carrier_stock_lots' lots_write policy (0006) is `FOR ALL ... USING
--      (carrier_id = authz.my_carrier_id())` with a matching WITH CHECK, and
--      0010 GRANTs INSERT/UPDATE/DELETE on the table to authenticated -- a
--      raw PostgREST call from any carrier can insert a lot straight into
--      status='ACTIVE' with no cap on cost_basis_sen (R-1's RM200 ceiling),
--      no completed_count history check, no internal.fn_marketplace_gate
--      call (so a PROHIBITED or non-marketplace_enabled category is no
--      obstacle), and never touches carriers.inventory_at_risk_sen -- the
--      exact column ck_carrier_exposure (0006) exists to keep honest. That
--      inserted row would immediately appear in v_lot_listings, which any
--      authenticated buyer can already read. Every other money/inventory
--      table in this schema (lot_purchases, delivery_locations, promotions,
--      capacity_invites) is RPC-only by REVOKE; carrier_stock_lots was the
--      one exception, not a considered decision -- 0006's own header calls
--      Muatan Jual "schema ready, feature flag OFF", which a client-writable
--      table was never actually true of. Closed here the same way: REVOKE
--      the direct grant, add SECURITY DEFINER RPCs that enforce what the
--      raw policy did not.
--   2. sellers.onboarding_status (0007) -- the column
--      internal.fn_marketplace_gate's own p_seller check reads -- has no
--      writer anywhere in the schema. It can only ever be its DDL default,
--      'PENDING', so fn_marketplace_gate's p_seller branch could never pass
--      for anyone, ever. rpc_admin_set_seller_status (0023) exists but
--      writes sellers.status (the Jualan/general-seller verification_status
--      enum) and the 'seller' role grant -- a different column, a different
--      concern, confirmed by reading both migrations' own comments. Closed
--      here with the admin review + carrier acceptance RPCs Muatan Jual's
--      own onboarding_status enum was always designed to need.
--
-- Also closed, same read-the-live-schema method: ref.category_compliance
-- and public.seller_licences both REVOKE write from authenticated/anon
-- (0007) with no RPC to write them either -- an admin had no way to ever
-- open a category or verify a licence. Added below.
--
-- Still explicitly NOT done here, and not pretended otherwise: a settlement
-- RPC that posts a lot sale to internal.ledger_*. rpc_buy_from_lot (0006/
-- 0013) deliberately posts nothing -- its own header says checkout stays a
-- reservation record until muatan_jual_checkout_enabled's MJ-01 escrow
-- question is answered. This migration's ledger entry (in rpc_create_lot,
-- below) is the OTHER leg ADDENDUM-COMMERCE.md §5.4 describes -- "Lot
-- purchase (carrier's own capital)" -- which is the carrier spending their
-- own money on stock, not a customer's money moving through the platform,
-- so it carries none of MJ-01's escrow question.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- 1. Close the raw-write gap on carrier_stock_lots.
-- ════════════════════════════════════════════════════════════════════════════
DROP POLICY IF EXISTS lots_write ON public.carrier_stock_lots;
REVOKE INSERT, UPDATE, DELETE ON public.carrier_stock_lots FROM authenticated, anon;

-- ════════════════════════════════════════════════════════════════════════════
-- 2. Muatan Jual seller onboarding (ref.seller_onboarding_status, 0007).
-- ════════════════════════════════════════════════════════════════════════════

-- Extends 0016's rpc_apply_seller with the columns 0007 added afterward
-- (seller_kind, operating_address, service_area_id) -- all optional with
-- defaults matching sellers' own DDL defaults, so every existing caller
-- (plain Jualan sellers, who pass none of them) is unaffected. FR-440: "no
-- new identity model" -- a carrier applying for Muatan Jual is this same
-- RPC with seller_kind='carrier_trader', not a parallel application path.
CREATE OR REPLACE FUNCTION public.rpc_apply_seller(
  p_business_name TEXT, p_community_id UUID, p_ssm_reg_no TEXT DEFAULT NULL,
  p_seller_kind TEXT DEFAULT 'individual', p_operating_address TEXT DEFAULT NULL,
  p_service_area_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_seller public.sellers;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  IF length(trim(p_business_name)) < 3 THEN
    RAISE EXCEPTION 'BUSINESS_NAME_TOO_SHORT';
  END IF;

  IF p_seller_kind NOT IN ('individual','sole_prop','company','cooperative','carrier_trader') THEN
    RAISE EXCEPTION 'INVALID_SELLER_KIND';
  END IF;

  IF EXISTS (SELECT 1 FROM public.sellers WHERE user_id = v_uid) THEN
    RAISE EXCEPTION 'SELLER_APPLICATION_EXISTS';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.communities WHERE id = p_community_id) THEN
    RAISE EXCEPTION 'COMMUNITY_NOT_FOUND';
  END IF;

  INSERT INTO public.sellers
    (user_id, business_name, ssm_reg_no, community_id, status,
     seller_kind, operating_address, service_area_id)
  VALUES (v_uid, trim(p_business_name), NULLIF(trim(COALESCE(p_ssm_reg_no,'')),''),
          p_community_id, 'NOT_STARTED',
          p_seller_kind, NULLIF(trim(COALESCE(p_operating_address,'')),''), p_service_area_id)
  RETURNING * INTO v_seller;

  -- Granting the 'seller' role itself and moving status past NOT_STARTED is
  -- an admin-console action (docs/PRD.md FR-271) -- deliberately not done
  -- here, same boundary the carrier role already keeps. onboarding_status
  -- (the separate Muatan Jual track) starts at its own DDL default,
  -- 'PENDING', reviewed by rpc_admin_review_muatan_jual_seller below.
  RETURN jsonb_build_object(
    'seller_id', v_seller.id, 'status', v_seller.status,
    'onboarding_status', v_seller.onboarding_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_apply_seller(TEXT,UUID,TEXT,TEXT,TEXT,UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_apply_seller(TEXT,UUID,TEXT,TEXT,TEXT,UUID) TO authenticated;

/** Admin review of the Muatan Jual onboarding track specifically --
 *  sellers.onboarding_status, not sellers.status (rpc_admin_set_seller_status,
 *  0023, is that one; the two are independent, per this migration's header). */
CREATE OR REPLACE FUNCTION public.rpc_admin_review_muatan_jual_seller(
  p_seller_id UUID, p_status TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_seller public.sellers; v_status ref.seller_onboarding_status;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_status NOT IN ('DOCUMENT_REVIEW','APPROVED','REJECTED','SUSPENDED') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;
  v_status := p_status::ref.seller_onboarding_status;

  UPDATE public.sellers SET
    onboarding_status = v_status,
    rejection_reason  = CASE WHEN v_status IN ('REJECTED','SUSPENDED')
                             THEN p_reason ELSE rejection_reason END,
    updated_at = now()
  WHERE id = p_seller_id
  RETURNING * INTO v_seller;

  IF v_seller.id IS NULL THEN RAISE EXCEPTION 'SELLER_NOT_FOUND'; END IF;

  RETURN jsonb_build_object('seller_id', v_seller.id, 'onboarding_status', v_seller.onboarding_status);
END $$;

REVOKE ALL ON FUNCTION public.rpc_admin_review_muatan_jual_seller(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_admin_review_muatan_jual_seller(UUID,TEXT,TEXT) TO authenticated;

/** The seller's own acceptance step -- APPROVED -> ACTIVE, sets
 *  terms_accepted_at (0007's own column, never written anywhere until now).
 *  Only from APPROVED: a PENDING applicant has nothing to accept yet, and a
 *  REJECTED/SUSPENDED one does not get to self-reactivate. */
CREATE OR REPLACE FUNCTION public.rpc_accept_muatan_jual_terms()
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_seller public.sellers;
BEGIN
  SELECT * INTO v_seller FROM public.sellers WHERE user_id = (SELECT auth.uid());
  IF NOT FOUND THEN RAISE EXCEPTION 'SELLER_NOT_FOUND'; END IF;
  IF v_seller.onboarding_status <> 'APPROVED' THEN
    RAISE EXCEPTION 'ONBOARDING_NOT_APPROVED';
  END IF;

  UPDATE public.sellers
     SET onboarding_status = 'ACTIVE', terms_accepted_at = now(), updated_at = now()
   WHERE id = v_seller.id
  RETURNING * INTO v_seller;

  RETURN jsonb_build_object('seller_id', v_seller.id, 'onboarding_status', v_seller.onboarding_status);
END $$;

REVOKE ALL ON FUNCTION public.rpc_accept_muatan_jual_terms() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_muatan_jual_terms() TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. Admin compliance controls -- ref.category_compliance and
--    public.seller_licences both REVOKE write from every role (0007), with
--    nothing to write them until now.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.rpc_admin_update_category_compliance(
  p_category_id UUID,
  p_legal_status TEXT DEFAULT NULL,
  p_marketplace_enabled BOOLEAN DEFAULT NULL,
  p_legal_review_status TEXT DEFAULT NULL,
  p_requires_licence BOOLEAN DEFAULT NULL,
  p_licence_type TEXT DEFAULT NULL,
  p_max_txn_value_sen BIGINT DEFAULT NULL,
  p_compliance_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_row ref.category_compliance; v_actor UUID := (SELECT auth.uid());
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_legal_review_status IS NOT NULL
     AND p_legal_review_status NOT IN ('PENDING','IN_REVIEW','CLEARED','BLOCKED') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;

  UPDATE ref.category_compliance SET
    legal_status        = COALESCE(p_legal_status::ref.category_legal_status, legal_status),
    marketplace_enabled  = COALESCE(p_marketplace_enabled, marketplace_enabled),
    legal_review_status  = COALESCE(p_legal_review_status, legal_review_status),
    requires_licence     = COALESCE(p_requires_licence, requires_licence),
    licence_type         = COALESCE(p_licence_type, licence_type),
    max_txn_value_sen    = COALESCE(p_max_txn_value_sen, max_txn_value_sen),
    compliance_note      = COALESCE(p_compliance_note, compliance_note),
    reviewed_by          = CASE WHEN p_legal_review_status IS NOT NULL THEN v_actor ELSE reviewed_by END,
    reviewed_at          = CASE WHEN p_legal_review_status IS NOT NULL THEN now() ELSE reviewed_at END,
    updated_at           = now()
  WHERE category_id = p_category_id
  RETURNING * INTO v_row;

  -- ck_prohibited_not_enabled/ck_licence_has_type still guard the actual
  -- invariant at the row level; NOT FOUND here only means the wrong id.
  IF v_row.category_id IS NULL THEN RAISE EXCEPTION 'CATEGORY_NOT_FOUND'; END IF;

  RETURN jsonb_build_object(
    'category_id', v_row.category_id, 'legal_status', v_row.legal_status,
    'marketplace_enabled', v_row.marketplace_enabled,
    'legal_review_status', v_row.legal_review_status);
END $$;

REVOKE ALL ON FUNCTION public.rpc_admin_update_category_compliance(
  UUID,TEXT,BOOLEAN,TEXT,BOOLEAN,TEXT,BIGINT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_admin_update_category_compliance(
  UUID,TEXT,BOOLEAN,TEXT,BOOLEAN,TEXT,BIGINT,TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_verify_seller_licence(
  p_licence_id UUID, p_approve BOOLEAN, p_note TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_licence public.seller_licences; v_actor UUID := (SELECT auth.uid());
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  UPDATE public.seller_licences SET
    verification_status = CASE WHEN p_approve THEN 'VERIFIED' ELSE 'REJECTED' END,
    verified_by = v_actor,
    verified_at = now()
  WHERE id = p_licence_id
  RETURNING * INTO v_licence;

  IF v_licence.id IS NULL THEN RAISE EXCEPTION 'LICENCE_NOT_FOUND'; END IF;

  RETURN jsonb_build_object(
    'licence_id', v_licence.id, 'verification_status', v_licence.verification_status);
END $$;

REVOKE ALL ON FUNCTION public.rpc_admin_verify_seller_licence(UUID,BOOLEAN,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_admin_verify_seller_licence(UUID,BOOLEAN,TEXT) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. Lot lifecycle -- the RPCs that replace the raw write closed in §1.
-- ════════════════════════════════════════════════════════════════════════════

/** Create a DRAFT stock lot. R-1's own two mitigations
 *  (ADDENDUM-COMMERCE.md §6) enforced here, reading the same config keys
 *  0006 already seeded for exactly this purpose:
 *    - lot_max_value_sen (RM200 ceiling) against cost_basis_sen -- the
 *      carrier's actual capital at risk, the same basis
 *      internal.fn_expire_lots already write down on expiry.
 *    - lot_min_completed_deliveries (20) against carriers.completed_count --
 *      a brand-new carrier cannot open with inventory risk.
 *  Also posts the "carrier's own capital" ledger leg ADDENDUM-COMMERCE.md
 *  §5.4 describes for a lot purchase (DR Carrier Inventory / CR Carrier
 *  Payable) and raises carriers.inventory_at_risk_sen -- the same column
 *  ck_carrier_exposure (0006) already joins to COD and procurement advances,
 *  so a carrier already deep in COD exposure cannot also stack unlimited
 *  inventory risk on top of it. */
CREATE OR REPLACE FUNCTION public.rpc_create_lot(
  p_title TEXT, p_category_id UUID, p_qty_total NUMERIC,
  p_cost_basis_sen BIGINT, p_cost_receipt_path TEXT, p_price_per_unit_sen BIGINT,
  p_unit TEXT DEFAULT 'kg', p_handling_flags TEXT[] DEFAULT '{}',
  p_photo_paths TEXT[] DEFAULT '{}', p_sell_by TIMESTAMPTZ DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_carrier public.carriers;
  v_seller public.sellers;
  v_min_deliveries INT;
  v_max_value_sen BIGINT;
  v_lot public.carrier_stock_lots;
  v_txn UUID;
BEGIN
  SELECT * INTO v_carrier FROM public.carriers WHERE user_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_A_CARRIER'; END IF;

  SELECT * INTO v_seller FROM public.sellers WHERE user_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'SELLER_APPLICATION_REQUIRED'; END IF;

  -- Same gate rpc_buy_from_lot enforces at purchase time (0013), and checked
  -- in the same relative position: eligibility before field-level validation,
  -- so a marketplace that is not even live yet fails fast rather than
  -- validating a lot's fields it is not going to accept anyway. A carrier
  -- cannot draft a listing in a category the master switch or category
  -- compliance has not cleared, nor without their own onboarding_status
  -- (checked via p_seller) reaching ACTIVE.
  PERFORM internal.fn_marketplace_gate(
    p_category := p_category_id, p_seller := v_seller.id, p_checkout := false);

  IF length(trim(p_title)) NOT BETWEEN 3 AND 120 THEN RAISE EXCEPTION 'TITLE_TOO_SHORT'; END IF;
  IF p_qty_total <= 0 THEN RAISE EXCEPTION 'INVALID_QUANTITY'; END IF;
  IF p_cost_basis_sen < 0 OR p_price_per_unit_sen <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;
  IF p_cost_receipt_path IS NULL OR length(trim(p_cost_receipt_path)) = 0 THEN
    RAISE EXCEPTION 'COST_RECEIPT_REQUIRED';
  END IF;

  SELECT (value#>>'{}')::int INTO v_min_deliveries
    FROM ref.app_config WHERE key = 'lot_min_completed_deliveries';
  IF v_carrier.completed_count < v_min_deliveries THEN
    RAISE EXCEPTION 'LOT_HISTORY_REQUIRED';
  END IF;

  SELECT (value#>>'{}')::bigint INTO v_max_value_sen
    FROM ref.app_config WHERE key = 'lot_max_value_sen';
  IF p_cost_basis_sen > v_max_value_sen THEN
    RAISE EXCEPTION 'LOT_VALUE_EXCEEDS_LIMIT';
  END IF;

  IF v_carrier.cod_held_sen + v_carrier.procurement_advance_sen
     + v_carrier.inventory_at_risk_sen + p_cost_basis_sen > v_carrier.float_limit_sen THEN
    RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED';
  END IF;

  INSERT INTO public.carrier_stock_lots
    (carrier_id, seller_id, title, category_id, handling_flags, unit,
     qty_total, cost_basis_sen, cost_receipt_path, price_per_unit_sen,
     photo_paths, status, sell_by)
  VALUES
    (v_carrier.id, v_seller.id, trim(p_title), p_category_id,
     p_handling_flags::ref.handling_flag[], p_unit, p_qty_total,
     p_cost_basis_sen, p_cost_receipt_path, p_price_per_unit_sen,
     p_photo_paths, 'DRAFT', p_sell_by)
  RETURNING * INTO v_lot;

  IF p_cost_basis_sen > 0 THEN
    INSERT INTO internal.ledger_transactions
      (kind, reference_type, reference_id, idempotency_key, description)
    VALUES ('LOT_INVENTORY_PURCHASE', 'lot', v_lot.id, 'lot_create:'||v_lot.id::text,
            'Carrier stock lot capital: '||trim(p_title))
    RETURNING id INTO v_txn;
    PERFORM internal.fn_post(v_txn, 'CARRIER_INVENTORY:'||v_carrier.id, 'DEBIT', p_cost_basis_sen);
    PERFORM internal.fn_post(v_txn, 'CARRIER_PAYABLE:'||v_carrier.id, 'CREDIT', p_cost_basis_sen);
  END IF;

  UPDATE public.carriers
     SET inventory_at_risk_sen = inventory_at_risk_sen + p_cost_basis_sen
   WHERE id = v_carrier.id;

  RETURN jsonb_build_object('lot_id', v_lot.id, 'status', v_lot.status);
END $$;

REVOKE ALL ON FUNCTION public.rpc_create_lot(
  TEXT,UUID,NUMERIC,BIGINT,TEXT,BIGINT,TEXT,TEXT[],TEXT[],TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_lot(
  TEXT,UUID,NUMERIC,BIGINT,TEXT,BIGINT,TEXT,TEXT[],TEXT[],TIMESTAMPTZ) TO authenticated;

/** FR-442: attach a DRAFT lot to a trip -- it becomes visible on Papan Kirim
 *  along that corridor (trip_listings, from/to resolved from the trip's own
 *  origin/destination). Re-checks the marketplace gate at activation, not
 *  just at creation -- compliance status can move between the two. */
CREATE OR REPLACE FUNCTION public.rpc_attach_lot_to_trip(p_lot UUID, p_trip UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_carrier_id UUID := authz.my_carrier_id(); lot public.carrier_stock_lots; t public.trips;
BEGIN
  IF v_carrier_id IS NULL THEN RAISE EXCEPTION 'NOT_A_CARRIER'; END IF;

  SELECT * INTO lot FROM public.carrier_stock_lots
   WHERE id = p_lot AND carrier_id = v_carrier_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LOT_NOT_FOUND'; END IF;
  IF lot.status <> 'DRAFT' THEN RAISE EXCEPTION 'LOT_NOT_DRAFT'; END IF;

  SELECT * INTO t FROM public.trips WHERE id = p_trip AND carrier_id = v_carrier_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'TRIP_NOT_FOUND'; END IF;
  -- Same check and error code rpc_send_capacity_invite (0006) already uses
  -- for the identical concern: a trip that already left has no more corridor
  -- to be visible along.
  IF t.status NOT IN ('DRAFT','ANNOUNCED','BOARDING') THEN
    RAISE EXCEPTION 'TRIP_NOT_BOARDING';
  END IF;

  PERFORM internal.fn_marketplace_gate(
    p_category := lot.category_id, p_seller := lot.seller_id, p_checkout := false);

  UPDATE public.carrier_stock_lots
     SET trip_id = p_trip, status = 'ACTIVE', updated_at = now()
   WHERE id = p_lot;

  INSERT INTO public.trip_listings (lot_id, trip_id, from_node_id, to_node_id)
  VALUES (p_lot, p_trip, t.origin_node_id, t.dest_node_id)
  ON CONFLICT (lot_id, trip_id) DO UPDATE SET is_active = true;

  RETURN jsonb_build_object('lot_id', p_lot, 'trip_id', p_trip, 'status', 'ACTIVE');
END $$;

REVOKE ALL ON FUNCTION public.rpc_attach_lot_to_trip(UUID,UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_attach_lot_to_trip(UUID,UUID) TO authenticated;

/** Withdraw a lot from sale (DRAFT or ACTIVE only -- a SOLD_OUT/EXPIRED/
 *  WRITTEN_OFF lot has nothing left to withdraw). Deliberately does NOT
 *  relieve inventory_at_risk_sen or touch the ledger: the carrier still
 *  physically holds whatever was not sold, so the capital stays at risk
 *  until it actually sells through or internal.fn_expire_lots writes it
 *  down -- unlisting is not the same event as losing the stock. */
CREATE OR REPLACE FUNCTION public.rpc_withdraw_lot(p_lot UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_carrier_id UUID := authz.my_carrier_id(); lot public.carrier_stock_lots;
BEGIN
  IF v_carrier_id IS NULL THEN RAISE EXCEPTION 'NOT_A_CARRIER'; END IF;

  SELECT * INTO lot FROM public.carrier_stock_lots
   WHERE id = p_lot AND carrier_id = v_carrier_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'LOT_NOT_FOUND'; END IF;
  IF lot.status NOT IN ('DRAFT','ACTIVE') THEN RAISE EXCEPTION 'LOT_NOT_WITHDRAWABLE'; END IF;

  UPDATE public.carrier_stock_lots SET status = 'WITHDRAWN', updated_at = now() WHERE id = p_lot;
  UPDATE public.trip_listings SET is_active = false WHERE lot_id = p_lot;

  RETURN jsonb_build_object('lot_id', p_lot, 'status', 'WITHDRAWN');
END $$;

REVOKE ALL ON FUNCTION public.rpc_withdraw_lot(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_withdraw_lot(UUID) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. Storage -- lot photos (buyer-visible) and cost receipts (private, FR-447:
--    never exposed to buyers). Neither bucket has ever existed, the same gap
--    0014 found for `pod`.
-- ════════════════════════════════════════════════════════════════════════════
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lot-photos', 'lot-photos', true, 2097152, ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

-- Path convention {user_id}/{uuid}.{ext} -- same as product-images (0016):
-- the carrier's own auth uid, so ownership is a plain equality check.
CREATE POLICY lot_photos_insert_owner ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lot-photos' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
CREATE POLICY lot_photos_delete_owner ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'lot-photos' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
-- Public bucket: no SELECT policy needed, same reasoning as product-images.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('lot-receipts', 'lot-receipts', false, 5242880, ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY lot_receipts_insert_owner ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'lot-receipts' AND (storage.foldername(name))[1] = (SELECT auth.uid())::text);
-- Private bucket: owner and admin can read. FR-447 -- a receipt proves cost
-- basis for the carrier's own accounting and for admin/compliance review;
-- it is never a buyer's business.
CREATE POLICY lot_receipts_select_owner_or_admin ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'lot-receipts'
         AND ((storage.foldername(name))[1] = (SELECT auth.uid())::text OR authz.is_admin()));
