-- ============================================================================
-- KasihKirim — 0035_seller_dashboard_and_order_visibility.sql   (P2-C)
--
-- PHASE 2 seller flow. The Android seller app needs two reads the backend
-- has never exposed:
--
--   1. Aggregate dashboard counts (product/listing/order/low-stock).
--      Composing these from four separate client-side queries would work,
--      but a SECURITY DEFINER aggregate is one round trip instead of four,
--      and scopes every count to the caller's own seller_id by construction
--      rather than by trusting the client to filter correctly.
--
--   2. A seller's own order's delivery/payment status. kirim_select /
--      deliveries_select (0003) scope reads to the requester (buyer) and the
--      assigned carrier -- deliberately never the seller, since a seller has
--      no route/handover business in either table. rpc_delivery_transition
--      (0030) already lets a seller ACT on their own order's delivery
--      (OPEN_DISPUTE) by resolving the seller relationship inside itself,
--      SECURITY DEFINER, bypassing RLS; this adds the read-only equivalent
--      so the Android app can show the seller what's happening before/after
--      that action, without granting the seller a general SELECT on
--      kirim_requests/deliveries. RLS on those two tables is unchanged --
--      this is one narrow, ownership-checked function, the same shape
--      rpc_get_payment_status (0034) already uses for the buyer side.
--
-- Neither function writes anything. Neither touches internal.payments'
-- schema or any ledger table -- rpc_seller_order_status only reads the
-- latest payment row for display, the same read rpc_get_payment_status
-- already does for the buyer.
-- ============================================================================

/** Counts scoped to the caller's own seller row. Every number here is
 *  derivable by the client from listMyProducts/listMyOrders individually --
 *  this exists to save four round trips and four places that could each get
 *  the seller_id filter wrong, not to expose anything new. */
CREATE OR REPLACE FUNCTION public.rpc_seller_dashboard()
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_seller UUID;
  v_product_count INT; v_active_count INT; v_low_stock INT;
  v_pending_orders INT; v_completed_orders INT;
BEGIN
  SELECT id INTO v_seller FROM public.sellers WHERE user_id = auth.uid();
  IF v_seller IS NULL THEN RAISE EXCEPTION 'NOT_A_SELLER'; END IF;

  SELECT count(*), count(*) FILTER (WHERE status = 'active')
    INTO v_product_count, v_active_count
    FROM public.products
   WHERE seller_id = v_seller AND deleted_at IS NULL;

  -- "Low stock" mirrors the same comparison rpc_set_stock/rpc_adjust_stock's
  -- callers already reason about (available vs. safety_stock) -- on_hand
  -- here rather than available (on_hand - reserved), because a fully
  -- reserved-out product is a stockout warning regardless of what's already
  -- promised to existing orders.
  SELECT count(*) INTO v_low_stock
    FROM public.inventory i
    JOIN public.products p ON p.id = i.product_id
   WHERE p.seller_id = v_seller AND p.deleted_at IS NULL
     AND i.on_hand <= i.safety_stock;

  SELECT
      count(*) FILTER (WHERE status NOT IN (
        'FULFILLED','SETTLED','CANCELLED','REJECTED_BY_SELLER',
        'REFUNDED','PARTIALLY_REFUNDED','PAYMENT_FAILED','EXPIRED')),
      count(*) FILTER (WHERE status IN ('FULFILLED','SETTLED'))
    INTO v_pending_orders, v_completed_orders
    FROM public.orders
   WHERE seller_id = v_seller;

  RETURN jsonb_build_object(
    'product_count',     v_product_count,
    'active_listings',   v_active_count,
    'low_stock_count',   v_low_stock,
    'pending_orders',    v_pending_orders,
    'completed_orders',  v_completed_orders);
END $$;

/** Read-only order/delivery/payment status for the order's own seller.
 *  delivery_id/delivery_status/carrier_assigned are NULL for an order never
 *  bridged to a delivery (e.g. still PENDING_PAYMENT) -- that is a normal,
 *  expected shape, not an error. */
CREATE OR REPLACE FUNCTION public.rpc_seller_order_status(p_order UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o public.orders; k public.kirim_requests; d public.deliveries; pay internal.payments;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO o FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.sellers s WHERE s.id = o.seller_id AND s.user_id = auth.uid()
  ) THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE order_id = p_order;
  IF FOUND THEN
    -- A retried delivery (retry_count > 0) can leave more than one row for
    -- the same kirim_id (one per attempt_no); the latest attempt is always
    -- the current one, the same ordering ux_delivery_active_kirim's own
    -- partial-uniqueness already treats as "the" active delivery.
    SELECT * INTO d FROM public.deliveries WHERE kirim_id = k.id ORDER BY attempt_no DESC LIMIT 1;
  END IF;

  SELECT * INTO pay FROM internal.payments
   WHERE reference_type = 'order' AND reference_id = p_order
   ORDER BY created_at DESC LIMIT 1;

  RETURN jsonb_build_object(
    'order_status',     o.status,
    'payment_status',   pay.status,
    'payment_method',   pay.method,
    'delivery_id',      d.id,
    'delivery_status',  d.status,
    'carrier_assigned', d.carrier_id IS NOT NULL);
END $$;

REVOKE ALL ON FUNCTION public.rpc_seller_dashboard()          FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_seller_dashboard()        TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_seller_order_status(UUID)    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_seller_order_status(UUID) TO authenticated;

COMMENT ON FUNCTION public.rpc_seller_order_status(UUID) IS
  'Read-only. Lets a seller see their own order''s delivery/payment status '
  'without a general SELECT grant on kirim_requests/deliveries -- the same '
  'ownership-checked-function shape as rpc_get_payment_status (0034) uses '
  'for the buyer side.';
