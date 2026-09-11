-- ============================================================================
-- KasihKirim — 0030_marketplace_authz_hardening.sql
--
-- Three defects found in the P1 final audit, two of them live.
--
-- ── 1. FORGED ORDER LINK (live, denial of service) ─────────────────────────
-- public.kirim_requests carries INSERT for `authenticated`, and kirim_insert
-- (0003) checks only `requester_id = auth.uid() AND status = 'DRAFT'`. Nothing
-- checks order_id. Any signed-in user could therefore insert a DRAFT PASARAN
-- kirim pointing at somebody else's order -- confirmed by probe: a stranger's
-- row landed on another buyer's order.
--
-- The row cannot be promoted to POSTED by its author (kirim_update_draft
-- pins status to DRAFT), so it never becomes a delivery. It does something
-- worse: fn_bridge_order_to_delivery treats "a kirim already exists for this
-- order" as "already bridged" and returns it. A stranger who learns an order
-- id can pre-seed a forged row and that order can NEVER be carried. The buyer
-- gets a payment intent and no delivery job, silently, forever.
--
-- Closed three ways, because one of them alone would still leave the
-- one-to-one relationship resting on a check-then-insert race:
--   * clients may no longer insert a PASARAN kirim at all -- the bridge is
--     the only legitimate creator and runs SECURITY DEFINER;
--   * a unique index makes order -> kirim structurally one-to-one;
--   * the bridge only accepts a pre-existing row as its own if that row is
--     a PASARAN kirim belonging to the order's actual buyer.
--
-- ── 2. FALSE DENIAL introduced by 0027 (live) ──────────────────────────────
-- 0027 closed a real hole: rpc_delivery_transition checked that the caller
-- HELD a role the transition permits, never that they were the party on this
-- delivery. The fix picked one role and then checked it -- but the pick came
-- first, `LIMIT 1` over the caller's roles, and the check came after.
--
-- DELIVERED --OPEN_DISPUTE--> DISPUTED permits {customer, seller, carrier}.
-- A seller almost always also holds `customer` (that is how sellers sign up),
-- roles arrive alphabetically, so 'customer' was picked -- and the seller is
-- not the delivery's requester, so their own order's dispute was refused.
-- Confirmed by probe: STATE_ACTOR_NOT_PERMITTED.
--
-- Rewritten to pick a role that is simultaneously held, permitted by the
-- rule, and substantiated by the caller's actual relationship to the
-- delivery. That closes the original hole AND removes the false denial:
-- neither is possible when the two questions are asked as one.
--
-- ── 3. Nothing here changes Kirim behaviour or moves any money. ────────────
-- ============================================================================

-- ── 1a. Clients cannot create a marketplace kirim ───────────────────────────
DROP POLICY IF EXISTS kirim_insert ON public.kirim_requests;
CREATE POLICY kirim_insert ON public.kirim_requests FOR INSERT TO authenticated
  WITH CHECK (
    requester_id = (SELECT auth.uid())
    AND status = 'DRAFT'
    -- A PASARAN kirim is created only by internal.fn_bridge_order_to_delivery,
    -- from an order the caller actually owns. Allowing a client to write one
    -- lets them point a row at any order id they can guess.
    AND kirim_type <> 'PASARAN');

-- ── 1b. One order, one delivery job ─────────────────────────────────────────
-- Deduplicate first: on a fresh database there is nothing to clean, but a
-- deployed database may already carry a forged row. Keep the row the order's
-- own buyer owns; drop anything else that never became a delivery.
DELETE FROM public.kirim_requests k
 WHERE k.order_id IS NOT NULL
   AND k.requester_id IS DISTINCT FROM (SELECT o.buyer_id FROM public.orders o WHERE o.id = k.order_id)
   AND NOT EXISTS (SELECT 1 FROM public.deliveries d WHERE d.kirim_id = k.id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_kirim_order
  ON public.kirim_requests (order_id) WHERE order_id IS NOT NULL;

-- ── 1c. The bridge only adopts a row it can vouch for ───────────────────────
CREATE OR REPLACE FUNCTION internal.fn_bridge_order_to_delivery(p_order UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  o public.orders; q internal.quotes; v_kirim UUID; v_ref TEXT;
  v_desc TEXT; v_addr UUID; v_expires TIMESTAMPTZ;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;

  -- Idempotent, but only for a row this function could itself have written:
  -- a PASARAN kirim owned by the order's actual buyer. Anything else is not
  -- this order's delivery job and must not be adopted as one.
  SELECT id INTO v_kirim FROM public.kirim_requests
   WHERE order_id = p_order AND kirim_type = 'PASARAN' AND requester_id = o.buyer_id
   LIMIT 1;
  IF v_kirim IS NOT NULL THEN RETURN v_kirim; END IF;

  IF o.quote_id IS NULL THEN RAISE EXCEPTION 'ORDER_NOT_PRICED'; END IF;
  IF COALESCE(o.discount_sen,0) <> 0 THEN RAISE EXCEPTION 'DISCOUNT_POLICY_UNDEFINED'; END IF;

  SELECT * INTO q FROM internal.quotes WHERE id = o.quote_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'QUOTE_NOT_FOUND'; END IF;

  v_addr := (o.address_snapshot->>'id')::uuid;
  IF v_addr IS NULL THEN RAISE EXCEPTION 'ORDER_ADDRESS_MISSING'; END IF;

  SELECT left(string_agg(oi.quantity || ' x ' || oi.title_snapshot, ', '
                         ORDER BY oi.title_snapshot), 480)
    INTO v_desc
    FROM public.order_items oi WHERE oi.order_id = p_order;
  v_desc := COALESCE(NULLIF(trim(v_desc),''), 'Pesanan ' || o.reference_code);
  IF length(v_desc) < 3 THEN v_desc := 'Pesanan ' || o.reference_code; END IF;

  v_ref := 'KK-' || to_char(now(),'YYMM') || '-'
           || lpad(nextval('internal.kirim_reference_seq')::text, 6, '0');
  v_expires := now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                         WHERE key='kirim_board_ttl_hours') || ' hours')::interval;

  INSERT INTO public.kirim_requests (
    reference_code, requester_id, kirim_type, status, item_description, category_id,
    est_weight_grams, volume_cm3, handling_flags, dest_address_id,
    origin_node_id, dest_node_id, quote_id, delivery_fee_sen, commission_sen,
    total_escrow_sen, payment_method, order_id, expires_at)
  VALUES (
    v_ref, o.buyer_id, 'PASARAN', 'POSTED', v_desc,
    (q.input_snapshot->>'category')::uuid,
    (q.input_snapshot->>'weight_g')::int,
    (q.input_snapshot->>'volume_cm3')::int,
    ARRAY(SELECT jsonb_array_elements_text(q.input_snapshot->'flags'))::ref.handling_flag[],
    v_addr,
    (q.input_snapshot->>'origin')::uuid,
    (q.input_snapshot->>'dest')::uuid,
    q.id, q.delivery_fee_sen, q.commission_sen,
    o.total_sen, 'COD', p_order, v_expires)
  RETURNING id INTO v_kirim;

  UPDATE internal.quotes SET consumed_at = now() WHERE id = q.id AND consumed_at IS NULL;
  RETURN v_kirim;
END $$;

-- ── 2. Substantiated role selection ─────────────────────────────────────────
/** Runs a delivery transition as the caller, in a role they hold, that the
 *  rule permits, AND that their actual relationship to this delivery
 *  supports. Asking those three questions separately is what produced both
 *  the pre-0027 hole (permitted but not substantiated) and 0027's own false
 *  denial (substantiated in one role, checked against another). */
CREATE OR REPLACE FUNCTION public.rpc_delivery_transition(
  p_delivery UUID, p_event TEXT,
  p_idempotency_key TEXT DEFAULT NULL, p_meta JSONB DEFAULT '{}')
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_role ref.user_role; v_new ref.kirim_status; v_roles TEXT[];
  v_uid UUID := auth.uid(); d public.deliveries; k public.kirim_requests;
  rule ref.delivery_transition_rules;
  v_is_customer BOOLEAN; v_is_carrier BOOLEAN; v_is_seller BOOLEAN;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;
  v_roles := authz.user_roles();
  IF array_length(v_roles,1) IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  SELECT * INTO rule FROM ref.delivery_transition_rules
   WHERE from_status = d.status AND event = p_event;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION: % from %', p_event, d.status;
  END IF;

  -- Who this caller actually is on THIS delivery.
  v_is_customer := (k.requester_id = v_uid);
  v_is_carrier  := (d.carrier_id IS NOT NULL AND d.carrier_id = authz.my_carrier_id());
  v_is_seller   := EXISTS (SELECT 1 FROM public.orders o
                             JOIN public.sellers s ON s.id = o.seller_id
                            WHERE o.id = k.order_id AND s.user_id = v_uid);

  -- Held, permitted, and substantiated -- all three, in one pass. Agent and
  -- admin roles are operational and hub-wide by design, so holding one is
  -- itself the substantiation.
  SELECT r::ref.user_role INTO v_role
    FROM unnest(v_roles) r
   WHERE r::ref.user_role = ANY(rule.allowed_roles)
     AND CASE r
           WHEN 'customer' THEN v_is_customer
           WHEN 'carrier'  THEN v_is_carrier
           WHEN 'seller'   THEN v_is_seller
           ELSE true
         END
   LIMIT 1;

  IF v_role IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  v_new := internal.fn_delivery_transition(
    p_delivery, p_event, v_uid, v_role, p_idempotency_key, p_meta);

  RETURN jsonb_build_object(
    'status', v_new,
    'next_events', COALESCE((SELECT jsonb_agg(event) FROM ref.delivery_transition_rules
                             WHERE from_status = v_new), '[]'::jsonb));
END $$;

REVOKE ALL ON FUNCTION internal.fn_bridge_order_to_delivery(UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.rpc_delivery_transition(UUID,TEXT,TEXT,JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delivery_transition(UUID,TEXT,TEXT,JSONB) TO authenticated;

COMMENT ON INDEX public.ux_kirim_order IS
  'One order, one delivery job. Makes the relationship structural rather than '
  'a check-then-insert inside the bridge.';
