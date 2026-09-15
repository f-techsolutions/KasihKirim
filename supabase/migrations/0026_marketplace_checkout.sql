-- ============================================================================
-- KasihKirim — 0026_marketplace_checkout.sql   (P1-B, P1-C, P1-M)
--
-- rpc_checkout (0020) creates an order that can never be delivered and can
-- never settle. Three defects, all fixed here, none of which change how a
-- Kirim behaves:
--
--   1. It prices no delivery. delivery_fee_sen is written as 0 and
--      total_sen as goods - discount, so the customer is never charged for
--      carriage and 0024's CARRIER allocation has nothing to draw on.
--      Fixed by quoting the delivery leg server-side through the existing
--      internal.fn_quote_kirim, the same pricing engine Kirim uses. No new
--      pricing model, and nothing priced on the client.
--
--   2. It applies vouchers. internal.fn_apply_voucher can set
--      discount_sen > 0, and internal.fn_allocate_order_payment (0024) then
--      raises ALLOCATION_DISCOUNT_UNSUPPORTED at settlement -- so a
--      discounted order takes the customer's money and can never release it.
--      Until the funding question is answered (P1-M below) a marketplace
--      checkout carrying a discount is refused at the door, where it is a
--      harmless error, rather than at settlement, where it is trapped money.
--
--   3. It collects no payment. The order sat at CREATED with no
--      internal.payments row, so nothing could ever capture, allocate or
--      settle. Fixed by creating a payment intent on the existing payments
--      table -- no second payment table, no new state machine.
--
-- Also closes the oversell hole 0025 prepared for: with an inventory row now
-- guaranteed for every product, a failed reservation is unconditionally
-- INSUFFICIENT_STOCK. The previous `IF NOT FOUND AND EXISTS (...)` meant an
-- untracked product sold without limit.
--
-- ── P1-M — DISCOUNT FUNDING POLICY (unresolved commercial decision) ─────────
-- A discount is somebody's money. Who funds a marketplace discount --
-- the seller, the platform, both on a split, or a specific campaign budget --
-- has not been decided, and the arithmetic cannot decide it: whichever party
-- the shortfall lands on is a real transfer from a real business.
-- Until that decision is made and funded:
--     discount_sen <> 0  ->  marketplace checkout is rejected.
-- Kirim vouchers are untouched: rpc_create_kirim and internal.fn_apply_voucher
-- keep working exactly as before, and voucher campaigns remain claimable.
-- ============================================================================

-- ── 1. Delivery pricing for a marketplace order ─────────────────────────────
/** Prices the carriage leg of an order through internal.fn_quote_kirim --
 *  the same base fare, corridor band, weight and handling table Kirim uses,
 *  and the same commission rule. Every input is read from the order and its
 *  items; none is supplied by the caller.
 *
 *  The quote is re-labelled subject_type='order' immediately, so it cannot be
 *  fed to rpc_create_kirim (which requires 'kirim') to conjure a free
 *  standalone delivery out of a marketplace price. */
CREATE OR REPLACE FUNCTION internal.fn_quote_order_delivery(p_order UUID)
RETURNS internal.quotes
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o public.orders; q internal.quotes;
  v_origin UUID; v_dest UUID; v_category UUID;
  v_weight INT; v_volume INT; v_flags ref.handling_flag[];
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  -- Origin: the seller's community. sellers.community_id is NOT NULL, but a
  -- community without a route node has no price and no corridor.
  SELECT c.node_id INTO v_origin
    FROM public.sellers s JOIN public.communities c ON c.id = s.community_id
   WHERE s.id = o.seller_id;
  IF v_origin IS NULL THEN RAISE EXCEPTION 'SELLER_ORIGIN_NODE_MISSING'; END IF;

  -- Destination: the address snapshotted onto the order at checkout.
  v_dest := COALESCE(
    (o.address_snapshot->>'nearest_node_id')::uuid,
    (SELECT c.node_id FROM public.communities c
      WHERE c.id = (o.address_snapshot->>'community_id')::uuid));
  IF v_dest IS NULL THEN RAISE EXCEPTION 'DEST_NODE_MISSING'; END IF;

  -- ck_distinct_nodes (0001) forbids a kirim whose origin and destination are
  -- the same route node, so a same-node order has no delivery to sell. Refused
  -- explicitly here rather than as a constraint violation three calls later.
  IF v_origin = v_dest THEN RAISE EXCEPTION 'SAME_NODE_DELIVERY_UNSUPPORTED'; END IF;

  SELECT COALESCE(SUM(p.weight_grams * oi.quantity), 0)::int,
         COALESCE(SUM(p.volume_cm3   * oi.quantity), 0)::int
    INTO v_weight, v_volume
    FROM public.order_items oi
    JOIN public.products p ON p.id = oi.product_id
   WHERE oi.order_id = p_order;

  -- Union of every line's handling requirements: one COLD_CHAIN item makes
  -- the whole consignment cold-chain, and the quote must say so.
  SELECT COALESCE(array_agg(DISTINCT f), '{}'::ref.handling_flag[])
    INTO v_flags
    FROM public.order_items oi
    JOIN public.products p ON p.id = oi.product_id
    CROSS JOIN LATERAL unnest(p.handling_flags) AS f
   WHERE oi.order_id = p_order;

  IF v_weight <= 0 THEN RAISE EXCEPTION 'ORDER_HAS_NO_ITEMS'; END IF;

  -- kirim_requests.est_weight_grams is CHECKed BETWEEN 100 AND 500000; the
  -- quote must stay inside the same envelope or the bridge cannot persist it.
  v_weight := GREATEST(100, LEAST(v_weight, 500000));
  v_volume := GREATEST(1, v_volume);

  -- Heaviest line decides the category, so the handling profile matches the
  -- bulk of what is actually being carried.
  SELECT p.category_id INTO v_category
    FROM public.order_items oi
    JOIN public.products p ON p.id = oi.product_id
   WHERE oi.order_id = p_order
   ORDER BY p.weight_grams * oi.quantity DESC, p.id
   LIMIT 1;

  q := internal.fn_quote_kirim(
         'PASARAN', v_category, v_weight, v_volume,
         0, v_origin, v_dest, v_flags, 'COD'::ref.payment_method, o.buyer_id);

  UPDATE internal.quotes SET subject_type = 'order' WHERE id = q.id
  RETURNING * INTO q;
  RETURN q;
END $$;

-- ── 2. Payment intent ───────────────────────────────────────────────────────
/** Opens the protected-payment record for an order on the existing
 *  internal.payments table.
 *
 *  COD is the only method ref.app_config.payment_methods_enabled permits, and
 *  ref.feature_gates.prepaid_payments_enabled is false pending MJ-01. Under
 *  COD the platform never holds the customer's money before delivery: the
 *  intent records what is owed and by whom, and the money enters the ledger
 *  when the carrier actually collects it. Prepaid authorisation would populate
 *  the same row through the same webhook path, which is why there is no
 *  second table and no second state machine here. */
CREATE OR REPLACE FUNCTION internal.fn_create_order_payment_intent(p_order UUID)
RETURNS internal.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.orders; pay internal.payments; v_methods JSONB;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF o.total_sen <= 0 THEN RAISE EXCEPTION 'ORDER_TOTAL_INVALID'; END IF;

  SELECT value INTO v_methods FROM ref.app_config WHERE key = 'payment_methods_enabled';
  IF v_methods IS NULL OR NOT (v_methods @> '["COD"]'::jsonb) THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_NOT_ENABLED';
  END IF;

  -- Replay of the same checkout returns the intent that already exists rather
  -- than opening a second claim on the same order.
  SELECT * INTO pay FROM internal.payments
   WHERE reference_type = 'order' AND reference_id = p_order
   ORDER BY created_at DESC LIMIT 1;
  IF FOUND THEN RETURN pay; END IF;

  INSERT INTO internal.payments (
    reference_type, reference_id, payer_id, provider, provider_ref,
    method, amount_sen, status, status_precedence, idempotency_key)
  VALUES (
    'order', p_order, o.buyer_id, 'cod', o.reference_code,
    'COD', o.total_sen, 'COD_PENDING',
    internal.fn_status_precedence('COD_PENDING'), 'order-intent:'||p_order::text)
  RETURNING * INTO pay;

  UPDATE public.orders
     SET status = 'PENDING_PAYMENT', payment_method = 'COD',
         updated_at = now()
   WHERE id = p_order;

  RETURN pay;
END $$;

-- ── 3. Checkout ─────────────────────────────────────────────────────────────
/** Server-authoritative checkout. Every sen is computed here:
 *
 *      goods_subtotal   = SUM(product.price_sen * quantity)   -- snapshotted
 *      delivery_fee     = quote.delivery_fee_sen              -- priced here
 *      commission       = goods_subtotal * seller commission_bps
 *      total            = goods_subtotal + delivery_fee
 *
 *  No total, price or fee is accepted from the caller: the only parameters
 *  are which address to ship to and, for Kirim-style vouchers, a code that
 *  marketplace checkout now refuses outright. */
CREATE OR REPLACE FUNCTION public.rpc_checkout(
  p_dest_address_id UUID,
  p_voucher_code TEXT DEFAULT NULL)
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

    -- Goods must be on the order before the carriage leg can be priced:
    -- fn_quote_order_delivery reads weight, volume and handling from the items.
    UPDATE public.orders SET
      goods_subtotal_sen = v_goods,
      commission_sen     = v_comm,
      discount_sen       = 0,
      total_sen          = v_goods,
      updated_at         = now()
    WHERE id = v_order_id;

    q := internal.fn_quote_order_delivery(v_order_id);

    UPDATE public.orders SET
      delivery_fee_sen = q.delivery_fee_sen,
      quote_id         = q.id,
      total_sen        = v_goods + q.delivery_fee_sen,
      updated_at       = now()
    WHERE id = v_order_id;

    pay := internal.fn_create_order_payment_intent(v_order_id);

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

-- ── 4. Grants ───────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.fn_quote_order_delivery(UUID)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_create_order_payment_intent(UUID)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpc_checkout(UUID,TEXT)                 FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_checkout(UUID,TEXT)              TO authenticated;

COMMENT ON FUNCTION internal.fn_create_order_payment_intent(UUID) IS
  'Opens the protected-payment record for an order on internal.payments. '
  'COD-only while ref.feature_gates.prepaid_payments_enabled is false (MJ-01).';
