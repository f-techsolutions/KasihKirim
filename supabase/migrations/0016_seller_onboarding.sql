-- ============================================================================
-- KasihKirim — 0016_seller_onboarding.sql
--
-- Closes the P1-B "Jualan" (Sales) spec's Phase A gap, confirmed live before
-- writing this: public.sellers/products/product_images/inventory/orders/
-- order_items all already exist and match docs/DATABASE.md exactly (this
-- migration does not touch that schema), but:
--
--   1. sellers has no INSERT policy anywhere and no apply RPC -- a user has
--      no self-service way to become a seller at all (confirmed via
--      pg_policy: only sellers_select/auth_admin_read_sellers exist, both
--      SELECT). Mirrors the same pre-existing gap on the carrier side
--      (rpc_apply_carrier doesn't exist either), so this is a new pattern,
--      not a copy of a broken one.
--   2. products_write already lets a seller INSERT/UPDATE their own row
--      directly (RLS: seller_id IN (SELECT id FROM sellers WHERE
--      user_id=auth.uid())) with NO status restriction at all -- confirmed
--      live via pg_policy. That means a seller can set their own product's
--      status straight to 'active' (or 'rejected'/'delisted') via a plain
--      Postgrest UPDATE, completely bypassing FR-271's admin moderation
--      queue. This migration does NOT touch products_write (an existing,
--      already-relied-upon RLS policy); it adds a protection trigger
--      alongside it, the same pattern 0002/0003 already use for
--      public.profiles (internal.tg_protect_profile_columns) and
--      public.trips (internal.tg_protect_trip_capacity).
--   3. product_images has a public SELECT policy (product_images_read,
--      USING true) but no write policy at all, and no storage bucket to
--      upload into -- docs/SECURITY.md §"Storage buckets" and
--      docs/ARCHITECTURE.md §12 both already design `product-images`
--      (public, path `{user_id}/{entity_id}/{uuid}.{ext}`, owning-seller
--      write, public read) but it was never created, the same gap
--      0014_delivery_proof_storage.sql closed for `pod`.
--
-- Out of scope here, by design (see docs/CARRIER_DEVICE_VALIDATION.md's
-- "Jualan scope" decision): checkout/cart, seller order-management, sales
-- dashboard, and payout RPCs. Those need orders/order_items/inventory
-- WRITE policies this migration does not add (confirmed live: today they
-- are SELECT-only), and depend on product listings existing first.
-- ============================================================================

-- ── 1. Self-service seller application ──────────────────────────────────────
-- SECURITY DEFINER is required for the same reason as every other
-- INSERT-into-a-SELECT-only-table RPC in this schema: search_path pinned to
-- '', every identifier schema-qualified.
CREATE OR REPLACE FUNCTION public.rpc_apply_seller(
  p_business_name TEXT, p_community_id UUID, p_ssm_reg_no TEXT DEFAULT NULL)
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

  IF EXISTS (SELECT 1 FROM public.sellers WHERE user_id = v_uid) THEN
    RAISE EXCEPTION 'SELLER_APPLICATION_EXISTS';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.communities WHERE id = p_community_id) THEN
    RAISE EXCEPTION 'COMMUNITY_NOT_FOUND';
  END IF;

  INSERT INTO public.sellers (user_id, business_name, ssm_reg_no, community_id, status)
  VALUES (v_uid, trim(p_business_name), NULLIF(trim(COALESCE(p_ssm_reg_no,'')),''),
          p_community_id, 'NOT_STARTED')
  RETURNING * INTO v_seller;

  -- Granting the 'seller' role itself and moving status past NOT_STARTED is
  -- an admin-console action (docs/PRD.md FR-271) -- deliberately not done
  -- here, same boundary the carrier role already keeps.
  RETURN jsonb_build_object(
    'seller_id', v_seller.id, 'status', v_seller.status);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_apply_seller(TEXT,UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_apply_seller(TEXT,UUID,TEXT) TO authenticated;

-- ── 2. Product moderation columns are admin-only, even though sellers can
--    otherwise write their own products row directly ────────────────────────
CREATE OR REPLACE FUNCTION internal.tg_protect_product_moderation_columns()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
  v_allowed BOOLEAN := (OLD.status, NEW.status) IN (
    ('draft','pending_review'), ('pending_review','draft'),
    ('active','paused'), ('paused','active'), ('rejected','draft')
  ) OR NEW.status = OLD.status;
BEGIN
  IF authz.is_admin() THEN RETURN NEW; END IF;

  IF NOT v_allowed THEN
    NEW.status := OLD.status;
  END IF;
  NEW.approved_by := OLD.approved_by;
  NEW.approved_at := OLD.approved_at;
  NEW.compliance_note := OLD.compliance_note;
  NEW.rejection_reason := OLD.rejection_reason;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER tg_products_protect_moderation
  BEFORE UPDATE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION internal.tg_protect_product_moderation_columns();

-- ── 3. product_images: sellers may attach/remove photos on their own
--    products (product_images itself has no seller_id -- go through the
--    product it belongs to, same join shape as inventory_own). ─────────────
CREATE POLICY product_images_write ON public.product_images
  FOR ALL TO authenticated
  USING (
    product_id IN (
      SELECT p.id FROM public.products p
      JOIN public.sellers s ON s.id = p.seller_id
      WHERE s.user_id = (SELECT auth.uid())
    )
  )
  WITH CHECK (
    product_id IN (
      SELECT p.id FROM public.products p
      JOIN public.sellers s ON s.id = p.seller_id
      WHERE s.user_id = (SELECT auth.uid())
    )
  );

-- At most 6 images per product (docs/PRD.md FR-272). A CHECK constraint
-- can't count sibling rows, so this is a trigger, same reasoning as every
-- other row-counting invariant in this schema (e.g. ux_addresses_one_default
-- needed a real constraint because it could be one; six distinct rows
-- cannot).
CREATE OR REPLACE FUNCTION internal.tg_limit_product_images()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF (SELECT count(*) FROM public.product_images WHERE product_id = NEW.product_id) >= 6 THEN
    RAISE EXCEPTION 'PRODUCT_IMAGE_LIMIT: max 6 images per product';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER tg_product_images_limit
  BEFORE INSERT ON public.product_images
  FOR EACH ROW
  EXECUTE FUNCTION internal.tg_limit_product_images();

-- ── 4. The product-images storage bucket ────────────────────────────────────
-- docs/SECURITY.md's own table: public=true, owning-seller write, public
-- read, no signed URL. Path convention (docs/ARCHITECTURE.md §"Storage"):
-- {user_id}/{entity_id}/{uuid}.{ext} -- the seller's own auth uid, not the
-- product id, is the first segment, which is what makes the RLS check a
-- plain equality instead of pod's join.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('product-images', 'product-images', true, 2097152,
        ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY product_images_bucket_insert_owner ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'product-images'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  );

CREATE POLICY product_images_bucket_delete_owner ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'product-images'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  );

-- No SELECT policy: the bucket is public (public=true), so
-- GET /storage/v1/object/public/product-images/... is served without going
-- through storage.objects RLS at all -- confirmed as the same reasoning
-- SECURITY.md gives for `avatars`, the other public bucket in its table.
