-- ============================================================================
-- KasihKirim — 0025_seller_product_stock.sql   (P1-A)
--
-- Makes stock server-authoritative for the marketplace.
--
-- The audit found one live oversell hole and one unfulfilled promise:
--
--   1. rpc_checkout (0020) reserves stock with a conditional UPDATE, then
--      raises INSUFFICIENT_STOCK only when an inventory row actually exists:
--
--        UPDATE public.inventory SET reserved = reserved + qty
--         WHERE product_id = ... AND on_hand - reserved >= qty;
--        IF NOT FOUND AND EXISTS (SELECT 1 FROM public.inventory
--                                  WHERE product_id = ...) THEN RAISE ...
--
--      A product with no inventory row therefore sells without limit --
--      nothing is reserved, nothing is checked, and the order is created.
--      public.inventory has no row for a product unless somebody inserted
--      one by hand, and neither rpc_create_product (0017) nor any trigger
--      does. Closed here by guaranteeing the row exists for every product,
--      past and future; 0026 then drops the EXISTS escape hatch so a missing
--      row can never again mean "unlimited".
--
--   2. 0006's comment on inventory_movements says "movements are append-only
--      via internal.fn_adjust_inventory". That function was never written and
--      nothing has ever written a movement row. Written here, under the name
--      the existing comment already promises.
--
-- ck_inventory_not_oversold (reserved <= on_hand) and the two >= 0 checks on
-- public.inventory (0001) remain the last line of defence: every path below
-- is written so the constraint is unreachable, not so it is bypassed.
-- ============================================================================

-- ── 1. Every product has an inventory row ───────────────────────────────────
-- Backfill first, so the invariant holds for rows that predate the trigger.
INSERT INTO public.inventory (product_id)
SELECT p.id FROM public.products p
ON CONFLICT (product_id) DO NOTHING;

CREATE OR REPLACE FUNCTION internal.tg_product_inventory_row()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO public.inventory (product_id) VALUES (NEW.id)
  ON CONFLICT (product_id) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_products_inventory_row ON public.products;
CREATE TRIGGER tg_products_inventory_row
  AFTER INSERT ON public.products
  FOR EACH ROW EXECUTE FUNCTION internal.tg_product_inventory_row();

-- ── 2. The single write path for on-hand stock ──────────────────────────────
/** Applies a signed delta to on_hand and records it. Refuses any delta that
 *  would drop on_hand below what is already reserved for live orders --
 *  a seller reducing stock must not be able to strand a paid reservation. */
CREATE OR REPLACE FUNCTION internal.fn_adjust_inventory(
  p_product   UUID,
  p_delta     INT,
  p_reason    TEXT,
  p_reference UUID DEFAULT NULL,
  p_actor     UUID DEFAULT NULL)
RETURNS public.inventory
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE inv public.inventory;
BEGIN
  SELECT * INTO inv FROM public.inventory WHERE product_id = p_product FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_NOT_FOUND'; END IF;

  IF inv.on_hand + p_delta < 0 THEN RAISE EXCEPTION 'STOCK_NEGATIVE'; END IF;
  IF inv.on_hand + p_delta < inv.reserved THEN RAISE EXCEPTION 'STOCK_BELOW_RESERVED'; END IF;

  UPDATE public.inventory
     SET on_hand = on_hand + p_delta, updated_at = now()
   WHERE product_id = p_product
  RETURNING * INTO inv;

  INSERT INTO public.inventory_movements (product_id, delta, reason, reference_id, created_by)
  VALUES (p_product, p_delta, p_reason, p_reference, p_actor);

  RETURN inv;
END $$;

-- ── 3. Reservation lifecycle for a marketplace order ────────────────────────
-- rpc_checkout takes the reservation. These two resolve it, and each is
-- idempotent through its own movement row: the marker is written in the same
-- transaction as the stock change, so a replay sees it and does nothing.
-- Neither ever moves money.

/** Reservation -> sold. Called when the carrier takes custody (PICKED_UP):
 *  that is the point the goods have left the seller for good. */
CREATE OR REPLACE FUNCTION internal.fn_commit_order_stock(p_order UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE it RECORD;
BEGIN
  IF EXISTS (SELECT 1 FROM public.inventory_movements
              WHERE reference_id = p_order AND reason = 'order_committed') THEN
    RETURN;
  END IF;

  FOR it IN SELECT product_id, quantity FROM public.order_items
             WHERE order_id = p_order ORDER BY product_id
  LOOP
    UPDATE public.inventory
       SET on_hand  = GREATEST(0, on_hand  - it.quantity),
           reserved = GREATEST(0, reserved - it.quantity),
           updated_at = now()
     WHERE product_id = it.product_id;

    INSERT INTO public.inventory_movements (product_id, delta, reason, reference_id)
    VALUES (it.product_id, -it.quantity, 'order_committed', p_order);
  END LOOP;
END $$;

/** Reservation -> back on the shelf. Called when an order can no longer be
 *  fulfilled: payment failed, checkout was abandoned, delivery cancelled.
 *  on_hand is untouched -- the goods never left. */
CREATE OR REPLACE FUNCTION internal.fn_release_order_stock(
  p_order UUID, p_reason TEXT DEFAULT 'order_released')
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE it RECORD;
BEGIN
  -- Already committed or already released: nothing held to give back.
  IF EXISTS (SELECT 1 FROM public.inventory_movements
              WHERE reference_id = p_order
                AND reason IN ('order_committed','order_released')) THEN
    RETURN;
  END IF;

  FOR it IN SELECT product_id, quantity FROM public.order_items
             WHERE order_id = p_order ORDER BY product_id
  LOOP
    UPDATE public.inventory
       SET reserved = GREATEST(0, reserved - it.quantity), updated_at = now()
     WHERE product_id = it.product_id;

    -- delta 0: on_hand did not move. The row exists to make the release
    -- auditable and to make this function idempotent.
    INSERT INTO public.inventory_movements (product_id, delta, reason, reference_id)
    VALUES (it.product_id, 0, p_reason, p_order);
  END LOOP;
END $$;

-- ── 4. Seller-facing stock RPCs ─────────────────────────────────────────────
-- public.inventory carries a SELECT policy for the owning seller (0003) but
-- no write grant at all, deliberately. These are the only way a seller
-- changes stock, and both verify ownership before touching anything.

CREATE OR REPLACE FUNCTION internal.fn_assert_product_owner(p_product UUID)
RETURNS UUID LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE v_seller UUID;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT p.seller_id INTO v_seller
    FROM public.products p
    JOIN public.sellers s ON s.id = p.seller_id
   WHERE p.id = p_product AND p.deleted_at IS NULL
     AND s.user_id = auth.uid();
  IF v_seller IS NULL THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;
  RETURN v_seller;
END $$;

/** Sets available quantity to an absolute figure. Refuses to cut below the
 *  quantity already reserved by live orders. */
CREATE OR REPLACE FUNCTION public.rpc_set_stock(
  p_product_id   UUID,
  p_on_hand      INT,
  p_safety_stock INT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE inv public.inventory; v_delta INT;
BEGIN
  PERFORM internal.fn_assert_product_owner(p_product_id);
  IF p_on_hand < 0 THEN RAISE EXCEPTION 'STOCK_NEGATIVE'; END IF;

  SELECT * INTO inv FROM public.inventory WHERE product_id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_NOT_FOUND'; END IF;

  v_delta := p_on_hand - inv.on_hand;
  IF v_delta <> 0 THEN
    inv := internal.fn_adjust_inventory(
             p_product_id, v_delta, 'seller_set_stock', NULL, auth.uid());
  END IF;

  IF p_safety_stock IS NOT NULL THEN
    IF p_safety_stock < 0 THEN RAISE EXCEPTION 'STOCK_NEGATIVE'; END IF;
    UPDATE public.inventory SET safety_stock = p_safety_stock, updated_at = now()
     WHERE product_id = p_product_id
    RETURNING * INTO inv;
  END IF;

  RETURN jsonb_build_object(
    'product_id', p_product_id, 'on_hand', inv.on_hand,
    'reserved', inv.reserved, 'safety_stock', inv.safety_stock,
    'available', inv.on_hand - inv.reserved);
END $$;

/** Relative stock movement -- a restock, a spoilage write-off, a correction. */
CREATE OR REPLACE FUNCTION public.rpc_adjust_stock(
  p_product_id UUID,
  p_delta      INT,
  p_reason     TEXT DEFAULT 'seller_adjust')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE inv public.inventory;
BEGIN
  PERFORM internal.fn_assert_product_owner(p_product_id);
  IF p_delta = 0 THEN RAISE EXCEPTION 'STOCK_DELTA_ZERO'; END IF;
  -- The reason is a seller-supplied label on an audit row, never a control
  -- value: it selects no branch and grants no privilege.
  inv := internal.fn_adjust_inventory(
           p_product_id, p_delta, COALESCE(NULLIF(trim(p_reason),''),'seller_adjust'),
           NULL, auth.uid());

  RETURN jsonb_build_object(
    'product_id', p_product_id, 'on_hand', inv.on_hand,
    'reserved', inv.reserved, 'safety_stock', inv.safety_stock,
    'available', inv.on_hand - inv.reserved);
END $$;

-- ── 5. Grants ───────────────────────────────────────────────────────────────
-- Postgres grants EXECUTE to PUBLIC on every new function; revoke first, then
-- grant only what a signed-in seller needs. The internal.* helpers get no
-- grant: schema internal has no USAGE for anon/authenticated (0000) and is
-- not PostgREST-exposed, and every caller is another definer function.
REVOKE ALL ON FUNCTION internal.tg_product_inventory_row()                       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_adjust_inventory(UUID,INT,TEXT,UUID,UUID)     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_commit_order_stock(UUID)                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_release_order_stock(UUID,TEXT)                FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_assert_product_owner(UUID)                    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_set_stock(UUID,INT,INT)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.rpc_adjust_stock(UUID,INT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_stock(UUID,INT,INT)     TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_adjust_stock(UUID,INT,TEXT) TO authenticated;

COMMENT ON FUNCTION internal.fn_adjust_inventory(UUID,INT,TEXT,UUID,UUID) IS
  'The only writer of public.inventory.on_hand. Records every change in '
  'public.inventory_movements and refuses to strand a live reservation.';
