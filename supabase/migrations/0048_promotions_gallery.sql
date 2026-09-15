-- ============================================================================
-- KasihKirim — 0048_promotions_gallery.sql
--
-- Phase 2's last remaining item: an admin-curated deals gallery for buyers.
-- Not to be confused with public.promotions (0006/0045, "Kongsi & Untung")
-- -- that table is a buyer/promoter's own referral codes. This is the
-- opposite direction: a small, admin-picked set of featured listings shown
-- to every buyer, the same way a marketplace app's home page highlights a
-- handful of deals. Hence a different name, public.deal_campaigns, so the
-- two are never confused in a query or a migration diff.
--
-- ── Design ───────────────────────────────────────────────────────────────
--   * One product per campaign (product_id NOT NULL, ON DELETE CASCADE) --
--     matching BuyListing's own one-product-at-a-time shape (Buy.kt has no
--     category/seller browse filter either). A campaign banner linking to
--     a whole seller or category is a bigger surface than this migration's
--     job; add it later if a real need shows up.
--   * public.deal_campaigns keeps its own admin-manageable RLS (is_active-
--     and-in-window OR is_admin()), the same posture as every other
--     admin-curated table in this schema. The buyer-facing read path is a
--     separate view, public.v_deal_campaigns, that also joins the product's
--     own live status -- a campaign whose product got paused or delisted
--     after the campaign was created must not keep showing it. This mirrors
--     v_lot_listings' (0006) own "id, joined display columns, WHERE the
--     underlying row is actually still live" shape.
--   * No Android UI calls the three admin RPCs below -- the admin console
--     is a separate Next.js app (docs/PRD.md's own platform table), the
--     same reasoning 0018_admin_product_review.sql gives for
--     rpc_admin_set_product_status. They exist so that console (or a
--     manual/service-role path, until it ships) has a real write surface,
--     narrower than direct table access.
-- ============================================================================

CREATE TABLE public.deal_campaigns (
  id         UUID PRIMARY KEY DEFAULT uuidv7(),
  title      TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
  subtitle   TEXT,
  image_path TEXT NOT NULL,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  sort_order INT NOT NULL DEFAULT 0,
  is_active  BOOLEAN NOT NULL DEFAULT true,
  starts_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  ends_at    TIMESTAMPTZ,
  created_by UUID NOT NULL REFERENCES public.profiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ends_at IS NULL OR ends_at > starts_at)
);
CREATE INDEX ix_deal_campaigns_product ON public.deal_campaigns(product_id);

ALTER TABLE public.deal_campaigns ENABLE ROW LEVEL SECURITY;

-- Admin-manageable read (the console's own list view, including
-- future/expired/inactive rows); the buyer's own read is v_deal_campaigns
-- below, not this table directly.
CREATE POLICY deal_campaigns_select ON public.deal_campaigns FOR SELECT TO authenticated
  USING ((is_active AND now() >= starts_at AND (ends_at IS NULL OR now() < ends_at))
         OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.deal_campaigns FROM authenticated, anon;
GRANT SELECT ON public.deal_campaigns TO authenticated;

-- The actual buyer-facing gallery: only campaigns that are active, inside
-- their own display window, AND whose linked product is still browsable
-- (same predicate BuyRepositoryImpl.browseProducts already applies).
-- security_barrier, same as v_lot_listings/v_badge_definitions -- a plain
-- read-only bridge, not a privilege boundary of its own (both underlying
-- tables keep their own RLS, which a view runs under by default).
CREATE VIEW public.v_deal_campaigns WITH (security_barrier=true) AS
  SELECT dc.id, dc.title, dc.subtitle, dc.image_path, dc.sort_order,
         p.id AS product_id, p.title AS product_title,
         p.price_sen, p.unit
  FROM public.deal_campaigns dc
  JOIN public.products p ON p.id = dc.product_id
  WHERE dc.is_active AND now() >= dc.starts_at AND (dc.ends_at IS NULL OR now() < dc.ends_at)
        AND p.status = 'active' AND p.deleted_at IS NULL;
GRANT SELECT ON public.v_deal_campaigns TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_create_deal_campaign(
  p_title TEXT, p_product_id UUID, p_image_path TEXT,
  p_subtitle TEXT DEFAULT NULL, p_sort_order INT DEFAULT 0,
  p_starts_at TIMESTAMPTZ DEFAULT now(), p_ends_at TIMESTAMPTZ DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_product_id) THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;
  IF p_ends_at IS NOT NULL AND p_ends_at <= p_starts_at THEN
    RAISE EXCEPTION 'INVALID_WINDOW';
  END IF;

  INSERT INTO public.deal_campaigns
    (title, subtitle, image_path, product_id, sort_order, starts_at, ends_at, created_by)
  VALUES
    (p_title, p_subtitle, p_image_path, p_product_id, p_sort_order, p_starts_at, p_ends_at,
     (SELECT auth.uid()))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id);
END $$;

REVOKE ALL ON FUNCTION
  public.rpc_admin_create_deal_campaign(TEXT,UUID,TEXT,TEXT,INT,TIMESTAMPTZ,TIMESTAMPTZ)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.rpc_admin_create_deal_campaign(TEXT,UUID,TEXT,TEXT,INT,TIMESTAMPTZ,TIMESTAMPTZ)
  TO authenticated;

/** Every field but p_id is optional -- NULL means "leave unchanged", the
 *  same convention rpc_admin_set_product_status's p_compliance_note (0018)
 *  already uses. Good enough for admin-console edits; a field that
 *  legitimately needs clearing to NULL (subtitle, ends_at) is re-sent as
 *  part of a full re-edit rather than solved with a separate sentinel. */
CREATE OR REPLACE FUNCTION public.rpc_admin_update_deal_campaign(
  p_id UUID, p_title TEXT DEFAULT NULL, p_subtitle TEXT DEFAULT NULL,
  p_image_path TEXT DEFAULT NULL, p_sort_order INT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL, p_ends_at TIMESTAMPTZ DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_campaign public.deal_campaigns;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  UPDATE public.deal_campaigns SET
    title      = COALESCE(p_title, title),
    subtitle   = COALESCE(p_subtitle, subtitle),
    image_path = COALESCE(p_image_path, image_path),
    sort_order = COALESCE(p_sort_order, sort_order),
    is_active  = COALESCE(p_is_active, is_active),
    ends_at    = COALESCE(p_ends_at, ends_at),
    updated_at = now()
  WHERE id = p_id
  RETURNING * INTO v_campaign;

  IF v_campaign.id IS NULL THEN RAISE EXCEPTION 'DEAL_CAMPAIGN_NOT_FOUND'; END IF;

  RETURN jsonb_build_object('id', v_campaign.id, 'is_active', v_campaign.is_active);
END $$;

REVOKE ALL ON FUNCTION
  public.rpc_admin_update_deal_campaign(UUID,TEXT,TEXT,TEXT,INT,BOOLEAN,TIMESTAMPTZ)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.rpc_admin_update_deal_campaign(UUID,TEXT,TEXT,TEXT,INT,BOOLEAN,TIMESTAMPTZ)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.rpc_admin_delete_deal_campaign(p_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;
  DELETE FROM public.deal_campaigns WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEAL_CAMPAIGN_NOT_FOUND'; END IF;
END $$;

REVOKE ALL ON FUNCTION public.rpc_admin_delete_deal_campaign(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_admin_delete_deal_campaign(UUID) TO authenticated;

-- ── Storage: deal banner images ──────────────────────────────────────────
-- Public bucket, admin-only write -- there is no per-owner folder check
-- (unlike product-images' {user_id}/... convention) because every writer
-- here is an admin acting on the platform's own behalf, not on their own
-- resource.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('deal-banners', 'deal-banners', true, 2097152,
        ARRAY['image/jpeg','image/png','image/webp'])
ON CONFLICT (id) DO NOTHING;

CREATE POLICY deal_banners_insert_admin ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'deal-banners' AND authz.is_admin());
CREATE POLICY deal_banners_delete_admin ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'deal-banners' AND authz.is_admin());
-- Public bucket: no SELECT policy needed, same reasoning as product-images.
