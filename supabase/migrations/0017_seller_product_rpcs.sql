-- ============================================================================
-- KasihKirim — 0017_seller_product_rpcs.sql
--
-- Two gaps found while building the Jualan (Phase A) Android screens against
-- 0016's schema, both confirmed live before writing this:
--
--   1. ref.categories is not PostgREST-exposed -- confirmed by grep, the
--      Android app already documents this exact limitation for
--      ref.route_nodes (OrdersViewModel's own comment) and works around it
--      for Kirim via rpc_quote_kirim's p_category_slug (resolved
--      server-side, never fetched client-side). A raw Postgrest INSERT into
--      products has no way to supply a real category_id at all -- there is
--      no client-reachable slug-to-id lookup. rpc_create_product/
--      rpc_update_product resolve it the same way rpc_quote_kirim already
--      does, rather than inventing a new public view onto `ref`.
--   2. internal.tg_protect_product_moderation_columns (0016) only fired
--      BEFORE UPDATE. products_write (pre-existing RLS) permits INSERT too,
--      and nothing stopped a direct Postgrest INSERT from setting
--      status='active' (or approved_by/approved_at/compliance_note)
--      straight in the insert payload -- there is no OLD row for a
--      BEFORE-UPDATE-only trigger to protect against on the very first
--      write. Extended to BEFORE INSERT OR UPDATE.
--
-- rpc_create_product/rpc_update_product are additive: they do not replace
-- products_write, which stays as the RLS boundary for both the RPC's own
-- UPDATE/INSERT and any other direct write (submit-for-review, pause/resume
-- -- plain status transitions the 0016 trigger already permits for a
-- non-admin, so those stay direct Postgrest calls, not new RPCs).
-- ============================================================================

CREATE OR REPLACE FUNCTION internal.tg_protect_product_moderation_columns()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF authz.is_admin() THEN RETURN NEW; END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.status := 'draft';
    NEW.approved_by := NULL;
    NEW.approved_at := NULL;
    NEW.compliance_note := NULL;
    NEW.rejection_reason := NULL;
    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.status, NEW.status) IN (
      ('draft','pending_review'), ('pending_review','draft'),
      ('active','paused'), ('paused','active'), ('rejected','draft')
    ) OR NEW.status = OLD.status
  ) THEN
    NEW.status := OLD.status;
  END IF;
  NEW.approved_by := OLD.approved_by;
  NEW.approved_at := OLD.approved_at;
  NEW.compliance_note := OLD.compliance_note;
  NEW.rejection_reason := OLD.rejection_reason;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS tg_products_protect_moderation ON public.products;
CREATE TRIGGER tg_products_protect_moderation
  BEFORE INSERT OR UPDATE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION internal.tg_protect_product_moderation_columns();

-- ── rpc_create_product ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_product(
  p_title TEXT, p_category_slug TEXT, p_price_sen BIGINT, p_weight_grams INT,
  p_description TEXT DEFAULT NULL, p_unit TEXT DEFAULT 'kg',
  p_volume_cm3 INT DEFAULT 8000, p_handling_flags TEXT[] DEFAULT '{}',
  p_min_order_qty INT DEFAULT 1)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_seller UUID; v_cat UUID; v_product public.products;
BEGIN
  SELECT id INTO v_seller FROM public.sellers WHERE user_id = (SELECT auth.uid());
  IF v_seller IS NULL THEN RAISE EXCEPTION 'NOT_A_SELLER'; END IF;

  SELECT id INTO v_cat FROM ref.categories WHERE slug = p_category_slug;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'CATEGORY_NOT_FOUND'; END IF;

  -- status is always 'draft' regardless of what's passed -- there is no
  -- p_status parameter at all, and the 0016/0017 trigger would force it
  -- back even if there were.
  INSERT INTO public.products (
    seller_id, title, description, category_id, price_sen,
    unit, weight_grams, volume_cm3, handling_flags, min_order_qty)
  VALUES (
    v_seller, p_title, p_description, v_cat, p_price_sen,
    p_unit, p_weight_grams, p_volume_cm3, p_handling_flags::ref.handling_flag[], p_min_order_qty)
  RETURNING * INTO v_product;

  RETURN jsonb_build_object('id', v_product.id, 'status', v_product.status);
END;
$function$;

REVOKE ALL ON FUNCTION
  public.rpc_create_product(TEXT,TEXT,BIGINT,INT,TEXT,TEXT,INT,TEXT[],INT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.rpc_create_product(TEXT,TEXT,BIGINT,INT,TEXT,TEXT,INT,TEXT[],INT)
TO authenticated;

-- ── rpc_update_product ───────────────────────────────────────────────────────
-- Deliberately no p_status parameter: status only ever moves via a direct
-- Postgrest UPDATE the 0017 trigger permits (submit/withdraw/pause/resume),
-- never through this function.
CREATE OR REPLACE FUNCTION public.rpc_update_product(
  p_product_id UUID, p_title TEXT, p_category_slug TEXT, p_price_sen BIGINT, p_weight_grams INT,
  p_description TEXT DEFAULT NULL, p_unit TEXT DEFAULT 'kg',
  p_volume_cm3 INT DEFAULT 8000, p_handling_flags TEXT[] DEFAULT '{}',
  p_min_order_qty INT DEFAULT 1)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_cat UUID; v_product public.products;
BEGIN
  SELECT id INTO v_cat FROM ref.categories WHERE slug = p_category_slug;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'CATEGORY_NOT_FOUND'; END IF;

  UPDATE public.products SET
    title = p_title, description = p_description, category_id = v_cat,
    price_sen = p_price_sen, unit = p_unit, weight_grams = p_weight_grams,
    volume_cm3 = p_volume_cm3, handling_flags = p_handling_flags::ref.handling_flag[],
    min_order_qty = p_min_order_qty, updated_at = now()
  WHERE id = p_product_id
    AND seller_id IN (SELECT id FROM public.sellers WHERE user_id = (SELECT auth.uid()))
  RETURNING * INTO v_product;

  IF v_product.id IS NULL THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;

  RETURN jsonb_build_object('id', v_product.id, 'status', v_product.status);
END;
$function$;

REVOKE ALL ON FUNCTION
  public.rpc_update_product(UUID,TEXT,TEXT,BIGINT,INT,TEXT,TEXT,INT,TEXT[],INT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.rpc_update_product(UUID,TEXT,TEXT,BIGINT,INT,TEXT,TEXT,INT,TEXT[],INT)
TO authenticated;
