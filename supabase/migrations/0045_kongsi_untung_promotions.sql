-- ============================================================================
-- KasihKirim — 0045_kongsi_untung_promotions.sql
--
-- Phase 2 (Trust & retention): Kongsi & Untung, the promoter/referral feature
-- documented in docs/ADDENDUM-COMMERCE.md §4 (Feature B).
--
-- IMPORTANT — this is NOT a from-scratch build. 0006_carrier_commerce.sql
-- already created public.promotions, public.promotion_attributions,
-- internal.tg_block_self_referral() / tg_attribution_self, and
-- internal.fn_attribute_promotion(code,buyer,order,kirim,order_total,
-- platform_commission) — the commission rate (25% of platform commission,
-- capped RM10) already lives in internal.commission_rules (context=
-- 'promoter'). None of it was ever wired up: there is no RPC a client can
-- call to create a code (INSERT is revoked on public.promotions with no
-- RPC to route through), no way to record a click, and nothing calls
-- fn_attribute_promotion from checkout or settlement. That's the actual
-- gap this migration closes. It does NOT redefine any table, trigger or
-- function 0006 already shipped.
--
-- Feature-gated OFF (ref.feature_gates.kongsi_untung_enabled = false,
-- unchanged here): docs/MUATAN-JUAL-COMPLIANCE.md flags the promoter-
-- disclosure and promoter-income-tax questions as "LEGAL REVIEW REQUIRED".
-- Every state-changing RPC below refuses outright while the gate is off;
-- read-only history (rpc_my_promotions) is not gated, the same as a
-- promoter can still see money they already earned if the gate is later
-- flipped off again.
--
-- ── Design decisions this migration makes ───────────────────────────────────
--   * promotion_clicks (new table): FR-421's "first click, 7-day window,
--     last-click-wins" needs an actual click record to measure the window
--     from; 0006 only tracks an aggregate click_count on promotions itself.
--     A click only records once the visitor is signed in and isn't the
--     promoter themselves — no anonymous/device-based fallback in this pass.
--   * subject_type is restricted to ('product','seller') by this migration's
--     own RPCs — 0006's CHECK also allows 'lot' (Muatan Jual carrier stock),
--     but muatan_jual_enabled is false and nothing sells lots yet.
--   * orders.promo_code (new column) records buyer intent at checkout time
--     (which click, if any, applies to this order) — money does not move
--     yet. fn_settle_delivery calls the existing fn_attribute_promotion once
--     the platform's real commission for that order is known, exactly the
--     same point PLATFORM_COMMISSION itself is credited. This keeps
--     0006's atomic "insert attribution + post ledger" function unchanged;
--     it is simply never called until now.
--   * FR-423's device/phone/bank overlap risk signal is out of scope --
--     promoter <> buyer (0006's own trigger, and fn_attribute_promotion's
--     own check) is what's enforced; a shared-device/shared-bank fraud
--     heuristic is a separate, later piece of work.
-- ============================================================================

-- ── 1. Schema additions ──────────────────────────────────────────────────────
-- Append-only click log: fn_settle_delivery has no need to read this
-- directly (it reads orders.promo_code, set once at checkout), but
-- resolving "which click, if any, applies" at checkout needs a real
-- per-buyer record to pick the most recent one from.
CREATE TABLE public.promotion_clicks (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  promotion_id  UUID NOT NULL REFERENCES public.promotions(id) ON DELETE CASCADE,
  buyer_id      UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  clicked_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_promotion_clicks_lookup ON public.promotion_clicks(buyer_id, clicked_at DESC);

ALTER TABLE public.orders ADD COLUMN promo_code TEXT REFERENCES public.promotions(code);

-- No direct client access -- every read/write of clicks goes through a
-- SECURITY DEFINER RPC, the same posture 0006 already took for promotions
-- and promotion_attributions.
ALTER TABLE public.promotion_clicks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.promotion_clicks FROM PUBLIC, anon, authenticated;

-- ── 2. Creating and opening a promotion ─────────────────────────────────────
/** Generates (or re-fetches) a share code for a product or seller. Idempotent
 *  per (promoter, subject) -- the UNIQUE(promoter_id,subject_type,subject_id)
 *  0006 already put on public.promotions -- so re-tapping "share" on the
 *  same product returns the same code rather than minting a second one. */
CREATE OR REPLACE FUNCTION public.rpc_create_promotion(p_subject_type TEXT, p_subject_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_existing public.promotions;
  v_code TEXT;
  v_row public.promotions;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT (SELECT enabled FROM ref.feature_gates WHERE key = 'kongsi_untung_enabled') THEN
    RAISE EXCEPTION 'KONGSI_UNTUNG_DISABLED';
  END IF;
  IF p_subject_type NOT IN ('product','seller') THEN RAISE EXCEPTION 'INVALID_SUBJECT_TYPE'; END IF;

  IF p_subject_type = 'product' THEN
    IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = p_subject_id AND status = 'active') THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
    END IF;
  ELSE
    IF NOT EXISTS (SELECT 1 FROM public.sellers WHERE id = p_subject_id AND status = 'APPROVED') THEN
      RAISE EXCEPTION 'SELLER_NOT_FOUND';
    END IF;
  END IF;

  SELECT * INTO v_existing FROM public.promotions
   WHERE promoter_id = v_uid AND subject_type = p_subject_type AND subject_id = p_subject_id;
  IF v_existing.id IS NOT NULL THEN
    RETURN jsonb_build_object('id', v_existing.id, 'code', v_existing.code,
      'subject_type', v_existing.subject_type, 'subject_id', v_existing.subject_id,
      'share_link', 'kasihkirim://promo/'||v_existing.code);
  END IF;

  v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  INSERT INTO public.promotions (promoter_id, subject_type, subject_id, code)
  VALUES (v_uid, p_subject_type, p_subject_id, v_code)
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('id', v_row.id, 'code', v_row.code,
    'subject_type', v_row.subject_type, 'subject_id', v_row.subject_id,
    'share_link', 'kasihkirim://promo/'||v_row.code);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_promotion(TEXT, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_promotion(TEXT, UUID) TO authenticated;

/** Resolves a shared code to what it promotes, and -- once the visitor is
 *  signed in and isn't the promoter -- records the click that starts
 *  FR-421's 7-day attribution window. A signed-out visitor still gets the
 *  subject back (so the app can show "open in KasihKirim" content before
 *  asking them to sign in), just with no click recorded yet. */
CREATE OR REPLACE FUNCTION public.rpc_open_promotion(p_code TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_promo public.promotions;
  v_subject JSONB;
BEGIN
  IF NOT (SELECT enabled FROM ref.feature_gates WHERE key = 'kongsi_untung_enabled') THEN
    RAISE EXCEPTION 'KONGSI_UNTUNG_DISABLED';
  END IF;

  SELECT * INTO v_promo FROM public.promotions WHERE code = upper(p_code) AND is_active;
  IF v_promo.id IS NULL THEN RETURN jsonb_build_object('found', false); END IF;

  IF v_promo.subject_type = 'product' THEN
    SELECT jsonb_build_object('title', p.title, 'price_sen', p.price_sen, 'seller_name', s.business_name)
      INTO v_subject
      FROM public.products p JOIN public.sellers s ON s.id = p.seller_id
     WHERE p.id = v_promo.subject_id AND p.status = 'active';
  ELSE
    SELECT jsonb_build_object('seller_name', s.business_name)
      INTO v_subject FROM public.sellers s WHERE s.id = v_promo.subject_id AND s.status = 'APPROVED';
  END IF;
  IF v_subject IS NULL THEN RETURN jsonb_build_object('found', false); END IF;

  UPDATE public.promotions SET click_count = click_count + 1 WHERE id = v_promo.id;

  IF v_uid IS NOT NULL AND v_uid <> v_promo.promoter_id THEN
    INSERT INTO public.promotion_clicks (promotion_id, buyer_id) VALUES (v_promo.id, v_uid);
  END IF;

  RETURN jsonb_build_object(
    'found', true,
    'subject_type', v_promo.subject_type,
    'subject_id', v_promo.subject_id,
    'subject', v_subject);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_open_promotion(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_open_promotion(TEXT) TO authenticated, anon;

/** The promoter's own dashboard: every code they've made, where its earnings
 *  stand (promotion_attributions.promoter_sen, 0006), and what's actually
 *  available to withdraw right now (PROMOTER_PAYABLE:<id> less anything
 *  already requested) -- the same available-minus-pending shape
 *  rpc_request_withdrawal itself uses. Not gated: a promoter can still see
 *  money already earned even if the feature is later switched off. */
CREATE OR REPLACE FUNCTION public.rpc_my_promotions()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_uid UUID := auth.uid(); v_promotions JSONB;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', p.id, 'code', p.code, 'subject_type', p.subject_type, 'subject_id', p.subject_id,
      'subject_label', CASE WHEN p.subject_type = 'product'
          THEN (SELECT pr.title FROM public.products pr WHERE pr.id = p.subject_id)
          ELSE (SELECT s.business_name FROM public.sellers s WHERE s.id = p.subject_id) END,
      'is_active', p.is_active, 'click_count', p.click_count,
      'pending_sen', COALESCE((SELECT sum(a.promoter_sen) FROM public.promotion_attributions a
                                 WHERE a.promotion_id = p.id AND a.status = 'PENDING'), 0),
      'settled_sen', COALESCE((SELECT sum(a.promoter_sen) FROM public.promotion_attributions a
                                 WHERE a.promotion_id = p.id AND a.status = 'SETTLED'), 0),
      'created_at', p.created_at
    ) ORDER BY p.created_at DESC), '[]'::jsonb)
    INTO v_promotions
    FROM public.promotions p WHERE p.promoter_id = v_uid;

  RETURN jsonb_build_object(
    'promotions', v_promotions,
    'available_sen', GREATEST(0,
      internal.fn_account_balance_sen('PROMOTER_PAYABLE:'||v_uid::text)
      - COALESCE((SELECT sum(amount_sen) FROM internal.payouts
                   WHERE payee_type = 'promoter' AND payee_id = v_uid
                     AND status IN ('REQUESTED','UNDER_REVIEW','APPROVED','BATCHED','PROCESSING')), 0)));
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_my_promotions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_promotions() TO authenticated;

-- ── 3. Checkout: record which click (if any) an order should be attributed
--      to, once the order's items and seller are known. No money moves yet
--      -- fn_attribute_promotion (0006) still requires the platform's real
--      commission for the order, which isn't known until settlement.
-- rpc_checkout (0026/0034), extended with promo_code resolution right after
-- the per-seller item loop. Everything else is unchanged from the version
-- 0034 left behind.
CREATE OR REPLACE FUNCTION public.rpc_checkout(
  p_dest_address_id UUID,
  p_voucher_code TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT 'COD')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_cart_id UUID;
  v_group UUID := gen_random_uuid();
  v_seller_id UUID;
  v_order_id UUID;
  v_ref TEXT;
  v_orders JSONB := '[]'::jsonb;
  v_item RECORD;
  v_default_bps INT;
  v_comm_bps INT;
  v_goods BIGINT;
  v_comm BIGINT;
  v_addr_snapshot JSONB;
  v_promo_code TEXT;
  q internal.quotes;
  pay internal.payments;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  -- P1-M: no funded discount policy, so no discounted marketplace order.
  IF p_voucher_code IS NOT NULL THEN
    RAISE EXCEPTION 'DISCOUNT_POLICY_UNDEFINED';
  END IF;

  SELECT to_jsonb(a) INTO v_addr_snapshot FROM public.addresses a
   WHERE a.id = p_dest_address_id AND a.user_id = v_uid AND a.deleted_at IS NULL;
  IF v_addr_snapshot IS NULL THEN RAISE EXCEPTION 'ADDRESS_NOT_FOUND'; END IF;

  SELECT id INTO v_cart_id FROM public.carts WHERE user_id = v_uid;
  IF v_cart_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.cart_items WHERE cart_id = v_cart_id
  ) THEN
    RAISE EXCEPTION 'CART_EMPTY';
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

      -- Atomic reserve-if-available. The predicate and the write are one
      -- statement, so two buyers racing for the last unit cannot both win;
      -- ck_inventory_not_oversold (0001) is the backstop, never the mechanism.
      --
      -- 0025 guarantees an inventory row for every product, so NOT FOUND now
      -- means exactly one thing: not enough stock. It previously also meant
      -- "no inventory row", which silently sold without limit.
      UPDATE public.inventory SET reserved = reserved + v_item.quantity, updated_at = now()
       WHERE product_id = v_item.product_id
         AND on_hand - reserved >= v_item.quantity;
      IF NOT FOUND THEN
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

    -- Kongsi & Untung: the most recent still-open click (FR-421, 7-day
    -- window, last-click-wins) against either this seller directly or one
    -- of the products actually in this order. A no-op (no rows) while the
    -- feature is off, since nothing ever populates promotion_clicks then.
    SELECT p.code INTO v_promo_code
      FROM public.promotion_clicks pc
      JOIN public.promotions p ON p.id = pc.promotion_id
     WHERE pc.buyer_id = v_uid
       AND pc.clicked_at > now() - INTERVAL '7 days'
       AND p.is_active
       AND p.promoter_id <> v_uid
       AND ( (p.subject_type = 'seller'  AND p.subject_id = v_seller_id)
          OR (p.subject_type = 'product' AND EXISTS (
                SELECT 1 FROM public.order_items oi
                 WHERE oi.order_id = v_order_id AND oi.product_id = p.subject_id)) )
     ORDER BY pc.clicked_at DESC
     LIMIT 1;

    -- Goods must be on the order before the carriage leg can be priced:
    -- fn_quote_order_delivery reads weight, volume and handling from the items.
    UPDATE public.orders SET
      goods_subtotal_sen = v_goods,
      commission_sen     = v_comm,
      discount_sen       = 0,
      total_sen          = v_goods,
      promo_code         = v_promo_code,
      updated_at         = now()
    WHERE id = v_order_id;

    q := internal.fn_quote_order_delivery(v_order_id);

    UPDATE public.orders SET
      delivery_fee_sen = q.delivery_fee_sen,
      quote_id         = q.id,
      total_sen        = v_goods + q.delivery_fee_sen,
      updated_at       = now()
    WHERE id = v_order_id;

    pay := internal.fn_create_order_payment_intent(v_order_id, p_payment_method);

    v_orders := v_orders || jsonb_build_object(
      'order_id', v_order_id, 'reference_code', v_ref, 'seller_id', v_seller_id,
      'goods_subtotal_sen', v_goods, 'delivery_fee_sen', q.delivery_fee_sen,
      'commission_sen', v_comm, 'discount_sen', 0,
      'total_sen', v_goods + q.delivery_fee_sen,
      'payment_id', pay.id, 'payment_status', pay.status,
      'payment_method', pay.method);
  END LOOP;

  DELETE FROM public.cart_items WHERE cart_id = v_cart_id;

  RETURN jsonb_build_object('order_group_id', v_group, 'orders', v_orders);
END $$;

-- ── 4. Settlement: attribute once the platform's real commission for this
--      order is known -- the same point PLATFORM_COMMISSION is credited.
-- CREATE OR REPLACE of fn_settle_delivery (last touched by 0024): the only
-- change is in the PASARAN branch -- tracking the PLATFORM allocation's
-- amount as the loop runs, then, once the order carries a promo_code,
-- calling 0006's own internal.fn_attribute_promotion with it. That function
-- posts its own balanced ledger transaction (DEBIT PLATFORM_COMMISSION /
-- CREDIT PROMOTER_PAYABLE, capped via internal.commission_rules), so the
-- CASE below still credits PLATFORM_COMMISSION in full first; the promoter's
-- cut is carved back out by fn_attribute_promotion's own entry. SELLER/
-- CARRIER/AGENT legs, the Kirim (BELI/HANTAR) branch, and everything else
-- are byte-for-byte unchanged from 0024.
CREATE OR REPLACE FUNCTION internal.fn_settle_delivery(p_delivery UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  d public.deliveries; k public.kirim_requests; q internal.quotes;
  pay internal.payments; a internal.payment_allocations;
  v_promo_code TEXT; v_buyer_id UUID; v_platform_amt BIGINT := 0;
  v_txn UUID; v_actual BIGINT; v_refund BIGINT; v_blocked TEXT;
  v_goods_held BIGINT; v_delivery_held BIGINT;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id=p_delivery FOR UPDATE;
  SELECT * INTO k FROM public.kirim_requests WHERE id=d.kirim_id;
  SELECT * INTO q FROM internal.quotes WHERE id=k.quote_id;

  v_blocked := internal.fn_settlement_blocked_reason(p_delivery);
  -- Settling twice is a no-op, not an error: fn_delivery_transition may be
  -- retried, and the caller has already got what it asked for.
  IF v_blocked = 'ALREADY_SETTLED' THEN RETURN; END IF;
  IF v_blocked IS NOT NULL THEN RAISE EXCEPTION '%', v_blocked; END IF;

  INSERT INTO internal.ledger_transactions (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('SETTLEMENT','delivery',p_delivery,'settle:'||p_delivery::text,'Settlement '||k.reference_code)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_txn;
  IF v_txn IS NULL THEN RETURN; END IF;   -- lost a concurrent race; already settled

  IF k.kirim_type = 'PASARAN' THEN
    -- ── Marketplace order ──────────────────────────────────────────────────
    -- The customer bought a product at the seller's price. There is no
    -- budget to reconcile and nothing to refund: every sen is already owed
    -- to a named party by the declared allocations.
    SELECT * INTO pay FROM internal.payments
     WHERE reference_type='order' AND reference_id=k.order_id
     ORDER BY created_at DESC LIMIT 1;

    SELECT COALESCE(SUM(amount_sen),0) INTO v_goods_held
      FROM internal.payment_allocations
     WHERE payment_id = pay.id AND allocation_type = 'SELLER';
    v_delivery_held := pay.amount_sen - v_goods_held;

    -- Release the holds funded at capture, then credit each party.
    PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','DEBIT',    v_goods_held);
    PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','DEBIT', v_delivery_held);

    FOR a IN SELECT * FROM internal.payment_allocations
              WHERE payment_id = pay.id ORDER BY allocation_type
    LOOP
      IF a.allocation_type NOT IN ('SELLER','CARRIER','AGENT') THEN
        v_platform_amt := v_platform_amt + a.amount_sen;
      END IF;
      PERFORM internal.fn_post(v_txn,
        CASE a.allocation_type
          WHEN 'SELLER'   THEN 'SELLER_PAYABLE:'||a.payee_id::text
          WHEN 'CARRIER'  THEN 'CARRIER_PAYABLE:'||a.payee_id::text
          WHEN 'AGENT'    THEN 'AGENT_PAYABLE'
          ELSE 'PLATFORM_COMMISSION'
        END, 'CREDIT', a.amount_sen);
    END LOOP;

    -- Kongsi & Untung: a promoter's cut comes out of the platform's own
    -- take, never the seller's or carrier's (FR-422) -- so this runs after
    -- the loop above, against the platform amount that loop just credited.
    SELECT promo_code, buyer_id INTO v_promo_code, v_buyer_id
      FROM public.orders WHERE id = k.order_id;
    IF v_promo_code IS NOT NULL AND v_platform_amt > 0 THEN
      PERFORM internal.fn_attribute_promotion(
        v_promo_code, v_buyer_id, k.order_id, NULL, pay.amount_sen, v_platform_amt);
    END IF;

    UPDATE internal.payment_allocations
       SET status='SETTLED', settled_at=now(), settlement_txn_id=v_txn, updated_at=now()
     WHERE payment_id = pay.id;

    UPDATE internal.payments
       SET status='SETTLED', status_precedence=internal.fn_status_precedence('SETTLED'),
           updated_at=now()
     WHERE id = pay.id;

    UPDATE public.orders SET status='SETTLED', updated_at=now() WHERE id = k.order_id;

  ELSE
    -- ── Kirim (BELI / HANTAR) — unchanged from 0003/0024 ───────────────────
    v_actual := COALESCE(k.actual_goods_sen, 0);
    v_refund := q.goods_budget_sen - v_actual;
    IF v_refund < 0 THEN RAISE EXCEPTION 'BR-915 VIOLATION: refund would be negative'; END IF;

    -- Goods leg: reimburse at cost, refund the remainder. No commission on goods.
    IF q.goods_budget_sen > 0 THEN
      PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','DEBIT',  q.goods_budget_sen);
      IF v_actual > 0 THEN
        PERFORM internal.fn_post(v_txn,'CARRIER_PAYABLE:'||d.carrier_id,'CREDIT', v_actual);
      END IF;
      IF v_refund > 0 THEN
        PERFORM internal.fn_post(v_txn,'REQUESTER_REFUND:'||k.requester_id,'CREDIT', v_refund);
      END IF;
    END IF;

    -- Service leg: commission out, remainder to the carrier.
    PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','DEBIT', q.delivery_fee_sen);
    PERFORM internal.fn_post(v_txn,'PLATFORM_COMMISSION','CREDIT', q.commission_sen);
    IF d.agent_fee_sen > 0 THEN
      PERFORM internal.fn_post(v_txn,'AGENT_PAYABLE','CREDIT', d.agent_fee_sen);
    END IF;
    PERFORM internal.fn_post(v_txn,'CARRIER_PAYABLE:'||d.carrier_id,'CREDIT',
                             q.delivery_fee_sen - q.commission_sen - d.agent_fee_sen);

    UPDATE public.carriers
       SET procurement_advance_sen = GREATEST(0, procurement_advance_sen - v_actual)
     WHERE id = d.carrier_id;
  END IF;

  UPDATE public.deliveries SET status='COMPLETED', completed_at=now() WHERE id=p_delivery;
  UPDATE public.kirim_requests SET status='COMPLETED' WHERE id=k.id;
  UPDATE public.carriers SET completed_count = completed_count + 1 WHERE id = d.carrier_id;
END;
$function$;

-- ── 5. Payouts: promoter joins carrier/seller in the same wallet/withdrawal
--      flow (FR-425). A promoter is any profile -- there is no separate
--      "promoters" table -- so its own payee_id is simply the caller's own
--      profile id, and its ledger account (upper(payee_type)||'_PAYABLE:'||
--      payee_id, unchanged from 0042) resolves to PROMOTER_PAYABLE:<id>,
--      exactly what fn_attribute_promotion (0006) already credits. ─────────
ALTER TABLE internal.payouts DROP CONSTRAINT payouts_payee_type_check;
ALTER TABLE internal.payouts ADD CONSTRAINT payouts_payee_type_check
  CHECK (payee_type IN ('carrier','seller','agent','promoter'));

CREATE OR REPLACE FUNCTION public.rpc_request_withdrawal(
  p_payee_type TEXT, p_bank_account_id UUID, p_amount_sen BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_payee_id UUID;
  v_available BIGINT;
  v_pending BIGINT;
  v_id UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_payee_type NOT IN ('carrier','seller','promoter') THEN RAISE EXCEPTION 'INVALID_PAYEE_TYPE'; END IF;
  IF p_amount_sen <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;

  v_payee_id := CASE p_payee_type
                  WHEN 'carrier'   THEN authz.my_carrier_id()
                  WHEN 'seller'    THEN authz.my_seller_id()
                  ELSE v_uid   -- promoter: any profile, no separate identity row
                END;
  IF v_payee_id IS NULL THEN
    RAISE EXCEPTION '%', CASE WHEN p_payee_type = 'carrier' THEN 'NOT_A_CARRIER' ELSE 'NOT_A_SELLER' END;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM internal.bank_accounts
                  WHERE id = p_bank_account_id AND owner_id = v_uid) THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_NOT_FOUND';
  END IF;

  v_available := internal.fn_account_balance_sen(upper(p_payee_type)||'_PAYABLE:'||v_payee_id::text);
  SELECT COALESCE(SUM(amount_sen), 0) INTO v_pending
    FROM internal.payouts
   WHERE payee_type = p_payee_type AND payee_id = v_payee_id
     AND status IN ('REQUESTED','UNDER_REVIEW','APPROVED','BATCHED','PROCESSING');

  IF p_amount_sen > (v_available - v_pending) THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE'; END IF;

  INSERT INTO internal.payouts (payee_type, payee_id, amount_sen, bank_account_id)
  VALUES (p_payee_type, v_payee_id, p_amount_sen, p_bank_account_id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'status', 'REQUESTED', 'amount_sen', p_amount_sen);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_my_payouts()
RETURNS TABLE (
  id UUID, payee_type TEXT, amount_sen BIGINT, status TEXT,
  bank_code TEXT, account_no_last4 TEXT,
  requested_at TIMESTAMPTZ, paid_at TIMESTAMPTZ, failure_reason TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id, p.payee_type, p.amount_sen, p.status::text,
         b.bank_code, b.account_no_last4, p.requested_at, p.paid_at, p.failure_reason
    FROM internal.payouts p
    JOIN internal.bank_accounts b ON b.id = p.bank_account_id
   WHERE (p.payee_type = 'carrier'  AND p.payee_id = authz.my_carrier_id())
      OR (p.payee_type = 'seller'   AND p.payee_id = authz.my_seller_id())
      OR (p.payee_type = 'promoter' AND p.payee_id = (SELECT auth.uid()))
   ORDER BY p.requested_at DESC;
$$;

CREATE OR REPLACE FUNCTION public.rpc_admin_list_payouts()
RETURNS TABLE (
  id UUID, payee_type TEXT, payee_label TEXT, amount_sen BIGINT, status TEXT,
  bank_code TEXT, account_no_last4 TEXT, holder_name TEXT,
  reviewed_by UUID, approved_by UUID, requested_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  RETURN QUERY
  SELECT p.id, p.payee_type,
         CASE p.payee_type
           WHEN 'carrier' THEN (SELECT pr.full_name FROM public.carriers c
                                 JOIN public.profiles pr ON pr.id = c.user_id WHERE c.id = p.payee_id)
           WHEN 'seller'  THEN (SELECT s.business_name FROM public.sellers s WHERE s.id = p.payee_id)
           ELSE (SELECT COALESCE(pr.full_name, pr.display_name) FROM public.profiles pr WHERE pr.id = p.payee_id)
         END,
         p.amount_sen, p.status::text,
         b.bank_code, b.account_no_last4, b.holder_name,
         p.reviewed_by, p.approved_by, p.requested_at
    FROM internal.payouts p
    JOIN internal.bank_accounts b ON b.id = p.bank_account_id
   WHERE p.status IN ('REQUESTED','UNDER_REVIEW','APPROVED','BATCHED','PROCESSING')
   ORDER BY p.requested_at ASC;
END;
$function$;

-- A promoter has no separate identity row -- any profile qualifies -- so
-- once kongsi_untung is enabled, anyone can be a payee and needs to be able
-- to add a bank account to receive it. While the gate stays off (current
-- production state), behaviour is byte-for-byte unchanged from 0042: a
-- plain customer with no carrier/seller id still cannot add one.
CREATE OR REPLACE FUNCTION public.rpc_add_bank_account(p_bank_code text, p_account_no text, p_holder_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public', 'extensions'
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_last4 TEXT;
  v_id UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF authz.my_carrier_id() IS NULL AND authz.my_seller_id() IS NULL
     AND NOT (SELECT enabled FROM ref.feature_gates WHERE key = 'kongsi_untung_enabled') THEN
    RAISE EXCEPTION 'NOT_A_PAYEE';
  END IF;

  IF trim(coalesce(p_bank_code,'')) = '' THEN RAISE EXCEPTION 'INVALID_BANK_CODE'; END IF;
  IF trim(coalesce(p_holder_name,'')) = '' THEN RAISE EXCEPTION 'INVALID_HOLDER_NAME'; END IF;

  v_last4 := right(regexp_replace(coalesce(p_account_no,''), '\D', '', 'g'), 4);
  IF length(v_last4) < 4 THEN RAISE EXCEPTION 'INVALID_ACCOUNT_NO'; END IF;

  INSERT INTO internal.bank_accounts
    (owner_id, bank_code, account_no_enc, account_no_last4, holder_name)
  VALUES (
    v_uid, upper(trim(p_bank_code)),
    pgp_sym_encrypt(p_account_no, internal.fn_bank_account_enc_key()),
    v_last4, trim(p_holder_name))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id, 'bank_code', upper(trim(p_bank_code)),
    'account_no_last4', v_last4, 'holder_name', trim(p_holder_name));
END;
$function$;
