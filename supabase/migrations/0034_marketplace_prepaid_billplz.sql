-- ============================================================================
-- KasihKirim — 0034_marketplace_prepaid_billplz.sql   (P2-A)
--
-- PHASE 2: prepaid payment intent, provider-agnostic at the DB layer,
-- Billplz-shaped at the Edge Function layer. This migration activates
-- NOTHING in production: ref.app_config.payment_methods_enabled stays
-- ["COD"], so every path added here that requires a non-COD method being
-- enabled is unreachable until someone deliberately edits that config row on
-- a specific project. That is the same production-safety pattern 0026/0027
-- already established for the marketplace checkout itself.
--
-- WHAT WAS ALREADY THERE (0004, 0005, 0027) and is NOT rebuilt here:
--   internal.payments / internal.webhook_events, fn_apply_payment_event,
--   fn_map_provider_status, fn_split_order_capture, fn_post, the ledger,
--   rpc_record_webhook, rpc_idem_store/lookup — all provider-agnostic
--   already, all reused verbatim. rpc_checkout's COD path is untouched
--   byte-for-byte; every existing call site (tests, the Android app) that
--   omits the new parameter gets exactly the behaviour it already has.
--
-- WHAT THIS MIGRATION ADDS:
--   1. internal.payments.checkout_url -- a hosted-payment-page URL, so a
--      client that lost connectivity mid-flow can ask for it again instead
--      of minting a second bill.
--   2. rpc_checkout / fn_create_order_payment_intent gain an optional
--      p_payment_method, defaulting to 'COD'. Choosing a non-COD, enabled
--      method skips the immediate bridge-to-delivery that COD does at
--      checkout: a prepaid order must not reach a carrier's board before it
--      is actually paid for, or a carrier could complete a real delivery for
--      an order that is never funded. fn_apply_payment_event bridges it once
--      the payment actually captures.
--   3. rpc_prepare_billplz_bill / rpc_record_billplz_bill: the two RPCs the
--      new payment-intent Edge Function calls, one as the buyer (validate +
--      read what a bill needs), one as service_role (persist what Billplz
--      actually returned -- a client must never set its own provider_ref).
--   4. rpc_get_payment_status: lets the buyer poll without re-deriving the
--      bill.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO:
--   No live Billplz refund call. fn_refund_order (0029) already reverses the
--   internal ledger correctly regardless of provider; actually returning
--   money to a payer's bank via Billplz's Refund API is a separate piece of
--   work, tracked, not started here -- exactly the "known remaining items"
--   pattern the rest of this project already uses for undecided or
--   unstarted surfaces.
-- ============================================================================

ALTER TABLE internal.payments
  ADD COLUMN IF NOT EXISTS checkout_url TEXT;

-- ── 1. Payment intent, method-aware ─────────────────────────────────────────
-- Reproduced from 0027 with one branch added. COD is byte-identical to
-- before, including bridging to delivery immediately -- that is what makes
-- COD safe to hand a carrier without waiting on anything.
CREATE OR REPLACE FUNCTION internal.fn_create_order_payment_intent(
  p_order UUID, p_method TEXT DEFAULT 'COD')
RETURNS internal.payments
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.orders; pay internal.payments; v_methods JSONB; v_enum ref.payment_method;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF o.total_sen <= 0 THEN RAISE EXCEPTION 'ORDER_TOTAL_INVALID'; END IF;

  BEGIN
    v_enum := p_method::ref.payment_method;
  EXCEPTION WHEN invalid_text_representation THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_UNKNOWN: %', p_method;
  END;

  SELECT value INTO v_methods FROM ref.app_config WHERE key = 'payment_methods_enabled';
  IF v_methods IS NULL OR NOT (v_methods @> to_jsonb(p_method)) THEN
    RAISE EXCEPTION 'PAYMENT_METHOD_NOT_ENABLED';
  END IF;

  -- Replay of the same checkout returns the intent that already exists
  -- rather than opening a second claim on the same order.
  SELECT * INTO pay FROM internal.payments
   WHERE reference_type = 'order' AND reference_id = p_order
   ORDER BY created_at DESC LIMIT 1;
  IF FOUND THEN RETURN pay; END IF;

  IF v_enum = 'COD' THEN
    INSERT INTO internal.payments (
      reference_type, reference_id, payer_id, provider, provider_ref,
      method, amount_sen, status, status_precedence, idempotency_key)
    VALUES (
      'order', p_order, o.buyer_id, 'cod', o.reference_code,
      'COD', o.total_sen, 'COD_PENDING',
      internal.fn_status_precedence('COD_PENDING'), 'order-intent:'||p_order::text)
    RETURNING * INTO pay;

    UPDATE public.orders
       SET status = 'PENDING_PAYMENT', payment_method = 'COD', updated_at = now()
     WHERE id = p_order;

    PERFORM internal.fn_bridge_order_to_delivery(p_order);
  ELSE
    -- Prepaid: the payment record exists, the bill does not yet. The Edge
    -- Function fills provider/provider_ref/checkout_url in once the gateway
    -- actually returns them (rpc_record_billplz_bill, below). Bridging to
    -- delivery waits for fn_apply_payment_event to see this payment captured
    -- -- see that function's own comment for why.
    INSERT INTO internal.payments (
      reference_type, reference_id, payer_id, provider, provider_ref,
      method, amount_sen, status, status_precedence, idempotency_key)
    VALUES (
      'order', p_order, o.buyer_id, 'pending', NULL,
      v_enum, o.total_sen, 'PENDING',
      internal.fn_status_precedence('PENDING'), 'order-intent:'||p_order::text)
    RETURNING * INTO pay;

    UPDATE public.orders
       SET status = 'PENDING_PAYMENT', payment_method = p_method, updated_at = now()
     WHERE id = p_order;
  END IF;

  RETURN pay;
END $$;

-- ── 2. Checkout, method-aware ────────────────────────────────────────────────
-- Reproduced from 0026 with one parameter added, defaulting to 'COD' so every
-- existing call (every test, the Android app today, all of which pass one or
-- two arguments by name) is unaffected byte-for-byte. Everything else --
-- server-derived totals, the discount refusal, the atomic reservation -- is
-- unchanged.
--
-- CREATE OR REPLACE cannot turn 0026's 2-argument function into this 3-argument
-- one -- Postgres identifies a function by (name, argument types), so a third
-- parameter makes a distinct overload, not a replacement. Left alone, the old
-- rpc_checkout(UUID,TEXT) would keep existing side by side with this one: two
-- copies of the same checkout logic that could silently diverge. Every
-- existing caller passes its arguments by name (Android's postgrest client
-- always does), so dropping the old overload changes nothing for them -- a
-- 1- or 2-argument named call now resolves to this function with
-- p_payment_method defaulting to 'COD', exactly as it defaulted before.
DROP FUNCTION IF EXISTS public.rpc_checkout(UUID, TEXT);

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

-- ── 3. Capture bridges a prepaid order to delivery ──────────────────────────
-- Reproduced from 0024 with one addition. A COD order already has a
-- delivery job the moment it is created (bridged at checkout, above); a
-- prepaid one deliberately does not, so that no carrier is ever handed an
-- order that might never be paid for. The moment the gateway actually
-- confirms the money, this is the first and only place that decides the
-- order is safe to carry.
CREATE OR REPLACE FUNCTION internal.fn_apply_payment_event(p_provider text, p_event_id text)
 RETURNS ref.payment_status
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  w internal.webhook_events; pay internal.payments;
  new_status ref.payment_status; v_txn UUID; k public.kirim_requests;
BEGIN
  SELECT * INTO w FROM internal.webhook_events
   WHERE provider=p_provider AND provider_event_id=p_event_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'WEBHOOK_EVENT_NOT_FOUND'; END IF;

  -- Row lock: two Edge instances handed the same event serialise here.
  SELECT * INTO pay FROM internal.payments
   WHERE provider=p_provider AND provider_ref = (w.payload->>'reference')
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;

  new_status := internal.fn_map_provider_status(p_provider, w.payload->>'status');

  IF internal.fn_status_precedence(new_status)
     <= internal.fn_status_precedence(pay.status) THEN
    UPDATE internal.webhook_events SET status='IGNORED_OUT_OF_ORDER'
     WHERE id = w.id;
    RETURN pay.status;                       -- stale event; no effect
  END IF;

  UPDATE internal.payments
     SET status = new_status,
         status_precedence = internal.fn_status_precedence(new_status),
         updated_at = now()
   WHERE id = pay.id;

  -- Money moves only on first successful capture. The ledger transaction's
  -- idempotency_key is UNIQUE, so a replay that somehow got this far still
  -- cannot post twice.
  IF new_status IN ('SUCCEEDED','CAPTURED') THEN
    INSERT INTO internal.ledger_transactions
      (kind, reference_type, reference_id, idempotency_key, description)
    VALUES ('PAYMENT_CAPTURE', pay.reference_type, pay.reference_id,
            'capture:'||pay.id::text, 'Capture '||p_provider||' '||p_event_id)
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING id INTO v_txn;

    IF v_txn IS NOT NULL THEN
      PERFORM internal.fn_post(v_txn,'GATEWAY_CLEARING','DEBIT', pay.amount_sen);

      IF pay.reference_type = 'kirim' THEN
        SELECT * INTO k FROM public.kirim_requests WHERE id = pay.reference_id;
        -- Goods and delivery escrow are separate accounts so that the BELI
        -- refund invariant (BR-915) is checkable in isolation.
        IF COALESCE(k.budget_cap_sen,0) > 0 THEN
          PERFORM internal.fn_post(v_txn,'ESCROW_HELD_GOODS','CREDIT', k.budget_cap_sen);
        END IF;
        PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','CREDIT',
                                 pay.amount_sen - COALESCE(k.budget_cap_sen,0));
      ELSIF pay.reference_type = 'order' THEN
        -- 0024: a marketplace order's goods share belongs in the goods
        -- escrow, so settlement's SELLER leg has a funded account to debit.
        PERFORM internal.fn_split_order_capture(v_txn, pay.id, pay.amount_sen);

        -- 0034: a prepaid order was never bridged to delivery at checkout.
        -- It is safe to hand to a carrier now, and not one moment sooner --
        -- fn_bridge_order_to_delivery is idempotent, so this is harmless to
        -- call even if something upstream already did (it never does, for
        -- a non-COD method, but idempotency is cheap insurance).
        IF pay.method <> 'COD' THEN
          PERFORM internal.fn_bridge_order_to_delivery(pay.reference_id);
        END IF;
      ELSE
        PERFORM internal.fn_post(v_txn,'ESCROW_HELD_DELIVERY','CREDIT', pay.amount_sen);
      END IF;
    END IF;
  END IF;

  IF new_status IN ('FAILED','CANCELLED','EXPIRED') AND pay.reference_type='kirim' THEN
    UPDATE public.kirim_requests SET status='DRAFT', updated_at=now()
     WHERE id = pay.reference_id AND status = 'POSTED';
  END IF;

  -- 0034: a prepaid order that failed/expired/was cancelled at the gateway
  -- never got as far as a delivery job (nothing to release) and never took
  -- money (nothing to refund) -- release the stock reservation and let the
  -- buyer try again, exactly like an abandoned COD checkout would.
  IF new_status IN ('FAILED','CANCELLED','EXPIRED') AND pay.reference_type='order' THEN
    PERFORM internal.fn_release_order_stock(pay.reference_id, 'payment_failed');
    UPDATE public.orders SET status='CANCELLED', updated_at=now()
     WHERE id = pay.reference_id AND status NOT IN ('SETTLED','REFUNDED','PARTIALLY_REFUNDED');
  END IF;

  UPDATE internal.webhook_events
     SET status='PROCESSED', processed_at=now()
   WHERE id = w.id;

  RETURN new_status;
END $function$;

-- ── 4. What a bill needs, and where its result goes ─────────────────────────
/** Read-side for the payment-intent Edge Function: what a Billplz bill needs
 *  to be created, and whether one already exists so a retry does not mint a
 *  second one. Ownership-checked; the caller must be the order's own buyer.
 *  Never calls out to a gateway itself -- that is the Edge Function's job,
 *  because internal.* has no network access and should not gain any. */
CREATE OR REPLACE FUNCTION internal.fn_prepare_billplz_bill(p_order UUID, p_actor UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.orders; pay internal.payments; pr public.profiles;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF o.buyer_id IS DISTINCT FROM p_actor THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO pay FROM internal.payments
   WHERE reference_type='order' AND reference_id=p_order
   ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_MISSING'; END IF;
  IF pay.method = 'COD' THEN RAISE EXCEPTION 'PAYMENT_METHOD_IS_COD'; END IF;
  IF pay.status NOT IN ('PENDING','INITIATED') THEN
    RAISE EXCEPTION 'PAYMENT_NOT_PENDING: %', pay.status;
  END IF;

  SELECT * INTO pr FROM public.profiles WHERE id = o.buyer_id;

  -- public.profiles has no email column (email lives in auth.users, which
  -- no marketplace internal function reads today) -- Billplz's Bills API
  -- accepts either email or mobile, so mobile alone is sufficient and this
  -- avoids adding a new dependency on the auth schema for a nice-to-have.
  RETURN jsonb_build_object(
    'payment_id', pay.id,
    'already_created', pay.provider_ref IS NOT NULL,
    'checkout_url', pay.checkout_url,
    'amount_sen', pay.amount_sen,
    'reference_code', o.reference_code,
    'name', COALESCE(pr.full_name, 'Pelanggan'),
    'mobile', pr.phone);
END $$;

/** Write-side, service_role only: persists what the gateway actually
 *  returned. A client must never be able to set its own provider_ref or
 *  checkout_url -- that would let it point a payment record at a bill it
 *  did not pay for, or claim a bill was created when it was not. */
CREATE OR REPLACE FUNCTION internal.fn_record_billplz_bill(
  p_payment_id UUID, p_bill_id TEXT, p_checkout_url TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  UPDATE internal.payments
     SET provider = 'billplz', provider_ref = p_bill_id,
         checkout_url = p_checkout_url, updated_at = now()
   WHERE id = p_payment_id AND provider_ref IS NULL;
  -- No FOUND check: a retry that lost the race to another instance finds
  -- the row already filled in, which is the same outcome, not an error.
END $$;

CREATE OR REPLACE FUNCTION public.rpc_prepare_billplz_bill(p_order UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  RETURN internal.fn_prepare_billplz_bill(p_order, auth.uid());
END $$;

CREATE OR REPLACE FUNCTION public.rpc_record_billplz_bill(
  p_payment_id UUID, p_bill_id TEXT, p_checkout_url TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  PERFORM internal.fn_record_billplz_bill(p_payment_id, p_bill_id, p_checkout_url);
END $$;

-- ── 5. Status polling ────────────────────────────────────────────────────────
/** Lets the buyer ask where their own payment stands without re-deriving a
 *  bill. Read-only, ownership-checked. */
CREATE OR REPLACE FUNCTION public.rpc_get_payment_status(p_order UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE o public.orders; pay internal.payments;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO o FROM public.orders WHERE id = p_order;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF o.buyer_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO pay FROM internal.payments
   WHERE reference_type='order' AND reference_id=p_order
   ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_MISSING'; END IF;

  RETURN jsonb_build_object(
    'payment_id', pay.id, 'status', pay.status, 'method', pay.method,
    'amount_sen', pay.amount_sen, 'checkout_url', pay.checkout_url,
    'order_status', o.status);
END $$;

-- ── 6. Grants ────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.fn_create_order_payment_intent(UUID,TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_apply_payment_event(TEXT,TEXT)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_prepare_billplz_bill(UUID,UUID)        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION internal.fn_record_billplz_bill(UUID,TEXT,TEXT)    FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_checkout(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_checkout(UUID,TEXT,TEXT) TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_prepare_billplz_bill(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_prepare_billplz_bill(UUID) TO authenticated;

-- Edge Function only, using the service_role key -- the same trust boundary
-- as rpc_record_webhook and rpc_apply_payment_event (0005).
REVOKE ALL ON FUNCTION public.rpc_record_billplz_bill(UUID,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_record_billplz_bill(UUID,TEXT,TEXT) TO service_role;

REVOKE ALL ON FUNCTION public.rpc_get_payment_status(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_payment_status(UUID) TO authenticated;

COMMENT ON COLUMN internal.payments.checkout_url IS
  'Hosted payment page URL for a prepaid method, so a client can ask again '
  'without minting a second bill. NULL for COD.';
COMMENT ON FUNCTION internal.fn_prepare_billplz_bill(UUID,UUID) IS
  'Read-only. Never calls a gateway -- the Edge Function does that. '
  'Returns already_created=true with the existing checkout_url on retry.';
