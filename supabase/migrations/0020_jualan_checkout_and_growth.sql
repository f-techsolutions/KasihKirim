-- ============================================================================
-- KasihKirim — 0020_jualan_checkout_and_growth.sql
--
-- Three independent, additive pieces requested as the next scoped slice of
-- work. None of them touch an existing function's body -- every one is a new
-- function or a new trigger on top of already-live tables, so nothing already
-- covered by CI/live traffic can regress.
--
-- (1) rpc_checkout — Jualan Phase B. carts/cart_items already had full RLS +
--     GRANT (0002/0010) so add/remove is a plain PostgREST call; the only gap
--     was turning a cart into public.orders/order_items, which orders_select/
--     order_items_select (0003) correctly only ever exposed as SELECT --
--     writing them needs the same SECURITY DEFINER bridge rpc_create_kirim
--     uses for kirim_requests. Price is resolved server-side from the live
--     product row (never the cart), matching BR-900's own comment on
--     cart_items. Delivery fee is intentionally 0: nothing in this schema
--     yet quotes a delivery leg for a Jualan order (that is a Kirim, a
--     separate object) -- the buyer arranges collection/delivery themselves.
--     Not fabricating a fee here is the same discipline as leaving the 22
--     districts without invented route distances.
--
--     Stock reservation only applies to products that have an `inventory`
--     row at all. No seller-facing inventory UI exists yet (Phase A shipped
--     catalog + moderation only), so most products currently have none --
--     for those, checkout treats supply as untracked/made-to-order rather
--     than inventing an on_hand figure. inventory.reserved is bumped but
--     nothing yet releases it (no seller order queue / cancel flow exists --
--     that is the next slice, not this one); documented here rather than
--     silently left for someone to discover.
--
--     Commission: sellers.commission_bps already exists as a per-seller
--     override column with no default-rate source anywhere. Reusing
--     internal.commission_rules directly is unsafe -- fn_quote_kirim's own
--     lookup (0003/0012) is `WHERE party='platform' ... ORDER BY
--     effective_from DESC LIMIT 1` with NO context filter, so inserting a
--     new platform/goods_subtotal row would silently hijack Kirim pricing
--     the moment its effective_from sorts first. A dedicated app_config key
--     avoids that landmine entirely; 1000 bps mirrors the existing Muatan
--     Jual platform rate on goods_subtotal (0006) as the closest existing
--     precedent for "goods sold through the app", not a fabricated figure.
--
--     No payment gateway is wired to orders (same gap already flagged for
--     Kirim -- FR references one but nothing in this schema implements it),
--     so payment_method stays NULL and no ledger entry is posted here. That
--     mirrors kirim_requests exactly: fn_settle_delivery/fn_apply_payment_event
--     post to the ledger at payment-capture time, never at creation time.
--
-- (2) rpc_claim_voucher — internal.fn_apply_voucher (0004) has existed since
--     the original schema but nothing has ever called it and nothing has
--     ever created a voucher_issuances row for a real user: campaigns_read
--     (0003) lets a user browse active campaigns, but there was no path from
--     "I can see this campaign" to "I hold a redeemable code". This adds
--     exactly that, respecting per_user_limit, then rpc_checkout accepts an
--     optional voucher code and calls the existing fn_apply_voucher against
--     it -- the first real caller that function has ever had.
--
-- (3) Badge auto-award — ref.badge_definitions/user_badges (0001) have
--     existed with zero rows and zero award path. Badge names/thresholds are
--     a product decision this session cannot invent wholesale (same
--     "no fabricated content" line as the route-distance and geography
--     gaps) -- so this seeds exactly three, each derived from a threshold or
--     status transition this schema already treats as meaningful elsewhere,
--     not a new number picked here:
--       verified_seller  -- sellers.status reaching APPROVED (0016)
--       verified_carrier -- carriers.status reaching APPROVED (0001)
--       trusted_carrier  -- carriers.completed_count reaching the existing
--                           ref.app_config 'lot_min_completed_deliveries'
--                           threshold (0006: "history required before
--                           selling", already 20)
--     This is a deliberately small starter set, not the full badge catalog.
--
-- Kongsi & Untung (promotions/promotion_attributions, also requested in this
-- batch) is NOT touched here. ref.app_config.feature_flags already carries
-- "kongsi_untung":false (0006) -- the same kind of deliberate business/legal
-- hold Muatan Jual is under, not an oversight. Building a promo-code issuance
-- path around a flag that says the feature isn't approved yet would be the
-- same mistake as fabricating route data: technically possible, not this
-- session's call to make. Flagged for the user rather than silently built or
-- silently skipped.
-- ============================================================================

-- ── (1) rpc_checkout ─────────────────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS internal.order_reference_seq START 1000;

INSERT INTO ref.app_config (key, value, description) VALUES
  ('default_seller_commission_bps', '1000',
   'Jualan platform commission when sellers.commission_bps is not set; mirrors the existing Muatan Jual goods_subtotal rate (0006)')
ON CONFLICT (key) DO NOTHING;

/** Turns the caller's cart into one order per seller represented in it
 *  (order_group_id ties them together), reserving stock where tracked and
 *  pricing every line from the live product row. p_voucher_code is only
 *  accepted when the cart holds a single seller's items -- fn_apply_voucher
 *  produces one discount for one order_total, and splitting one voucher's
 *  discount across several sellers' orders has no well-defined answer this
 *  schema takes a position on. */
CREATE OR REPLACE FUNCTION public.rpc_checkout(
  p_dest_address_id UUID,
  p_voucher_code TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_cart_id UUID;
  v_group UUID := gen_random_uuid();
  v_seller_id UUID;
  v_seller_count INT;
  v_order_id UUID;
  v_ref TEXT;
  v_orders JSONB := '[]'::jsonb;
  v_item RECORD;
  v_default_bps INT;
  v_comm_bps INT;
  v_goods BIGINT;
  v_comm BIGINT;
  v_discount BIGINT;
  v_addr_snapshot JSONB;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT to_jsonb(a) INTO v_addr_snapshot FROM public.addresses a
   WHERE a.id = p_dest_address_id AND a.user_id = v_uid AND a.deleted_at IS NULL;
  IF v_addr_snapshot IS NULL THEN RAISE EXCEPTION 'ADDRESS_NOT_FOUND'; END IF;

  SELECT id INTO v_cart_id FROM public.carts WHERE user_id = v_uid;
  IF v_cart_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.cart_items WHERE cart_id = v_cart_id
  ) THEN
    RAISE EXCEPTION 'CART_EMPTY';
  END IF;

  SELECT count(DISTINCT p.seller_id) INTO v_seller_count
  FROM public.cart_items ci JOIN public.products p ON p.id = ci.product_id
  WHERE ci.cart_id = v_cart_id;

  IF p_voucher_code IS NOT NULL AND v_seller_count > 1 THEN
    RAISE EXCEPTION 'VOUCHER_REQUIRES_SINGLE_SELLER';
  END IF;

  SELECT (value#>>'{}')::int INTO v_default_bps
    FROM ref.app_config WHERE key = 'default_seller_commission_bps';
  v_default_bps := COALESCE(v_default_bps, 1000);

  FOR v_seller_id IN
    SELECT DISTINCT p.seller_id FROM public.cart_items ci
    JOIN public.products p ON p.id = ci.product_id
    WHERE ci.cart_id = v_cart_id
  LOOP
    SELECT COALESCE(commission_bps, v_default_bps) INTO v_comm_bps
    FROM public.sellers WHERE id = v_seller_id;

    v_ref := 'ORD-' || to_char(now(),'YYMM') || '-'
             || lpad(nextval('internal.order_reference_seq')::text, 6, '0');

    INSERT INTO public.orders (
      order_group_id, reference_code, buyer_id, seller_id,
      goods_subtotal_sen, delivery_fee_sen, discount_sen, commission_sen, total_sen,
      address_snapshot)
    VALUES (
      v_group, v_ref, v_uid, v_seller_id,
      0, 0, 0, 0, 0, v_addr_snapshot)
    RETURNING id INTO v_order_id;

    v_goods := 0;
    FOR v_item IN
      SELECT ci.product_id, ci.quantity, p.title, p.price_sen, p.weight_grams, p.status
      FROM public.cart_items ci
      JOIN public.products p ON p.id = ci.product_id
      WHERE ci.cart_id = v_cart_id AND p.seller_id = v_seller_id
      FOR UPDATE OF p
    LOOP
      IF v_item.status <> 'active' THEN RAISE EXCEPTION 'PRODUCT_NOT_AVAILABLE'; END IF;

      UPDATE public.inventory SET reserved = reserved + v_item.quantity, updated_at = now()
       WHERE product_id = v_item.product_id
         AND on_hand - reserved >= v_item.quantity;
      IF NOT FOUND AND EXISTS (
        SELECT 1 FROM public.inventory WHERE product_id = v_item.product_id
      ) THEN
        RAISE EXCEPTION 'INSUFFICIENT_STOCK';
      END IF;

      INSERT INTO public.order_items (
        order_id, product_id, title_snapshot, price_sen, quantity, weight_grams, line_total_sen)
      VALUES (
        v_order_id, v_item.product_id, v_item.title, v_item.price_sen, v_item.quantity,
        v_item.weight_grams, v_item.price_sen * v_item.quantity);

      v_goods := v_goods + v_item.price_sen * v_item.quantity;
    END LOOP;

    v_comm := v_goods * v_comm_bps / 10000;
    v_discount := 0;
    IF p_voucher_code IS NOT NULL THEN
      v_discount := internal.fn_apply_voucher(v_uid, p_voucher_code, v_goods);
    END IF;

    UPDATE public.orders SET
      goods_subtotal_sen = v_goods,
      commission_sen = v_comm,
      discount_sen = v_discount,
      total_sen = v_goods - v_discount,
      updated_at = now()
    WHERE id = v_order_id;

    v_orders := v_orders || jsonb_build_object(
      'order_id', v_order_id, 'reference_code', v_ref, 'seller_id', v_seller_id,
      'goods_subtotal_sen', v_goods, 'discount_sen', v_discount, 'total_sen', v_goods - v_discount);
  END LOOP;

  DELETE FROM public.cart_items WHERE cart_id = v_cart_id;

  RETURN jsonb_build_object('order_group_id', v_group, 'orders', v_orders);
END $$;

-- ── (2) rpc_claim_voucher ────────────────────────────────────────────────────
/** Issues the caller one redeemable code from an active campaign, respecting
 *  per_user_limit. Does not touch budget_spent_sen -- that is spent only at
 *  redemption, by the existing fn_apply_voucher. */
CREATE OR REPLACE FUNCTION public.rpc_claim_voucher(p_campaign_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  c public.voucher_campaigns;
  v_count INT;
  v_code TEXT;
  v_id UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO c FROM public.voucher_campaigns WHERE id = p_campaign_id FOR UPDATE;
  IF NOT FOUND OR NOT c.is_active OR now() NOT BETWEEN c.starts_at AND c.ends_at THEN
    RAISE EXCEPTION 'CAMPAIGN_NOT_ACTIVE';
  END IF;
  IF c.budget_spent_sen >= c.budget_ceiling_sen THEN
    RAISE EXCEPTION 'CAMPAIGN_BUDGET_EXHAUSTED';
  END IF;

  SELECT count(*) INTO v_count FROM public.voucher_issuances
   WHERE campaign_id = p_campaign_id AND user_id = v_uid;
  IF v_count >= c.per_user_limit THEN RAISE EXCEPTION 'VOUCHER_LIMIT_REACHED'; END IF;

  v_code := c.code_prefix || '-' || upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8));

  INSERT INTO public.voucher_issuances (campaign_id, user_id, code, expires_at)
  VALUES (p_campaign_id, v_uid, v_code, c.ends_at)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('issuance_id', v_id, 'code', v_code, 'expires_at', c.ends_at);
END $$;

REVOKE ALL ON FUNCTION
  public.rpc_checkout(UUID,TEXT),
  public.rpc_claim_voucher(UUID)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.rpc_checkout(UUID,TEXT),
  public.rpc_claim_voucher(UUID)
TO authenticated;

-- ── (3) Badge auto-award ─────────────────────────────────────────────────────
INSERT INTO ref.badge_definitions (slug, name_ms, name_en, icon, rule, sort_order) VALUES
  ('verified_seller',  'Peniaga Disahkan',   'Verified Seller',
   'storefront', jsonb_build_object('on','sellers.status','value','APPROVED'), 10),
  ('verified_carrier', 'Pembawa Disahkan',   'Verified Carrier',
   'local_shipping', jsonb_build_object('on','carriers.status','value','APPROVED'), 20),
  ('trusted_carrier',  'Pembawa Dipercayai', 'Trusted Carrier',
   'military_tech', jsonb_build_object('on','carriers.completed_count',
     'gte_config_key','lot_min_completed_deliveries'), 30)
ON CONFLICT (slug) DO NOTHING;

CREATE OR REPLACE FUNCTION internal.fn_award_badge(p_user UUID, p_slug TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_badge UUID;
BEGIN
  IF p_user IS NULL THEN RETURN; END IF;
  SELECT id INTO v_badge FROM ref.badge_definitions WHERE slug = p_slug;
  IF v_badge IS NULL THEN RETURN; END IF;
  INSERT INTO public.user_badges (user_id, badge_id) VALUES (p_user, v_badge)
  ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION internal.tg_award_seller_verified_badge()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status = 'APPROVED' AND (OLD.status IS DISTINCT FROM 'APPROVED') THEN
    PERFORM internal.fn_award_badge(NEW.user_id, 'verified_seller');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_sellers_award_badge AFTER UPDATE OF status ON public.sellers
  FOR EACH ROW EXECUTE FUNCTION internal.tg_award_seller_verified_badge();

CREATE OR REPLACE FUNCTION internal.tg_award_carrier_badges()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_threshold INT;
BEGIN
  IF NEW.status = 'APPROVED' AND (OLD.status IS DISTINCT FROM 'APPROVED') THEN
    PERFORM internal.fn_award_badge(NEW.user_id, 'verified_carrier');
  END IF;

  IF NEW.completed_count IS DISTINCT FROM OLD.completed_count THEN
    SELECT (value#>>'{}')::int INTO v_threshold
      FROM ref.app_config WHERE key = 'lot_min_completed_deliveries';
    v_threshold := COALESCE(v_threshold, 20);
    IF NEW.completed_count >= v_threshold AND OLD.completed_count < v_threshold THEN
      PERFORM internal.fn_award_badge(NEW.user_id, 'trusted_carrier');
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_carriers_award_badges AFTER UPDATE OF status, completed_count ON public.carriers
  FOR EACH ROW EXECUTE FUNCTION internal.tg_award_carrier_badges();
