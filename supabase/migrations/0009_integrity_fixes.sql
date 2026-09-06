-- ============================================================================
-- KasihKirim — 0009_integrity_fixes.sql
--
-- Four defects found by the FIRST REAL TEST RUN (CI, migrations 0000-0008 and
-- seed all green). Forward-only: 0000-0008 have now genuinely applied, so they
-- are not edited.
--
--   P0-1  reserved_* could never change, so overbooking protection was inert
--   P0-2  kirim_requests <-> deliveries policies recursed infinitely
--   P1-3  ref.category_compliance was empty (populated before categories exist)
--   P1-4  FAILED_PICKUP was a dead-end state          <- see seed.sql
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- P0-1  CAPACITY INTEGRITY
--
-- The defect: internal.tg_protect_trip_capacity ran BEFORE UPDATE on trips and
-- unconditionally reverted reserved_* to OLD for any caller failing an
-- is_admin() check. internal.tg_sync_trip_reserved is SECURITY DEFINER, runs as
-- postgres with no JWT, and therefore failed that check -- so its own UPDATE
-- was silently reverted. reserved_* never left 0, the three CHECK constraints
-- were unreachable, and BR-903 was inert in production.
--
-- The fix uses three independent layers and never uses "admin" as a proxy for
-- "trusted server code":
--
--   Layer 1  column privileges  -- authenticated has no UPDATE on reserved_*
--   Layer 2  trusted-context trigger -- raises loudly on any other writer
--   Layer 3  the existing CHECK constraints, now actually reachable
-- ════════════════════════════════════════════════════════════════════════════

-- ── Layer 1: authenticated may update trip metadata, never capacity ─────────
-- A missing privilege fails with 42501 at the privilege check, before any
-- trigger runs. This is the difference between "cannot" and "is quietly undone".
REVOKE UPDATE ON public.trips FROM authenticated;
GRANT  UPDATE (status, depart_at, depart_window_minutes, arrive_est_at,
               corridor_nodes, accepts_cod, accepts_beli, recurring_rule,
               handling_capabilities, vehicle_id, updated_at)
  ON public.trips TO authenticated;

-- ── Layer 2: only the reservation sync path may move reserved_* ─────────────
-- The GUC is transaction-local and is set by the two capacity functions below.
-- PostgREST cannot issue a bare SET, and no user-callable RPC sets it, so a
-- client cannot manufacture the trusted context.
CREATE OR REPLACE FUNCTION internal.tg_protect_trip_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  -- reserved_*: writable ONLY from the capacity-sync context.
  IF (NEW.reserved_weight_grams, NEW.reserved_volume_cm3, NEW.reserved_parcels)
     IS DISTINCT FROM
     (OLD.reserved_weight_grams, OLD.reserved_volume_cm3, OLD.reserved_parcels)
     AND coalesce(current_setting('kasihkirim.capacity_sync', true), '') <> 'on'
  THEN
    RAISE EXCEPTION
      'CAPACITY_DIRECT_WRITE_FORBIDDEN: reserved_* is maintained by '
      'internal.fn_reserve_capacity / fn_release_capacity only'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- capacity_*: frozen once the trip leaves DRAFT. State-dependent, so this
  -- cannot be expressed as a column grant. Admins may still correct it.
  IF OLD.status <> 'DRAFT' AND NOT authz.is_admin() THEN
    NEW.capacity_weight_grams := OLD.capacity_weight_grams;
    NEW.capacity_volume_cm3   := OLD.capacity_volume_cm3;
    NEW.capacity_parcels      := OLD.capacity_parcels;
  END IF;

  RETURN NEW;
END $$;

-- ── The only two writers, each opening the trusted context explicitly ───────
CREATE OR REPLACE FUNCTION internal.fn_reserve_capacity(
  p_trip UUID, p_kirim UUID, p_w INT, p_v INT, p_p INT, p_ttl_min INT DEFAULT 30)
RETURNS UUID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_trip public.trips; v_id UUID;
BEGIN
  SELECT * INTO v_trip FROM public.trips WHERE id = p_trip FOR UPDATE;  -- serialise
  IF NOT FOUND THEN RAISE EXCEPTION 'TRIP_NOT_FOUND'; END IF;
  IF v_trip.status NOT IN ('ANNOUNCED','BOARDING') THEN
    RAISE EXCEPTION 'TRIP_NOT_BOARDING'; END IF;
  IF v_trip.reserved_weight_grams + p_w > v_trip.capacity_weight_grams
     OR v_trip.reserved_volume_cm3 + p_v > v_trip.capacity_volume_cm3
     OR v_trip.reserved_parcels    + p_p > v_trip.capacity_parcels THEN
    RAISE EXCEPTION 'CAPACITY_EXCEEDED';
  END IF;

  PERFORM set_config('kasihkirim.capacity_sync', 'on', true);   -- txn-local
  INSERT INTO public.trip_reservations
    (trip_id,kirim_id,status,weight_grams,volume_cm3,parcels,expires_at)
  VALUES (p_trip,p_kirim,'HELD',p_w,p_v,p_p, now() + (p_ttl_min||' minutes')::interval)
  RETURNING id INTO v_id;
  -- The AFTER trigger recomputes reserved_* and the CHECK constraints fire.
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION internal.fn_release_capacity(
  p_reservation UUID, p_reason TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  PERFORM set_config('kasihkirim.capacity_sync', 'on', true);
  UPDATE public.trip_reservations
     SET status = 'RELEASED', released_at = now()
   WHERE id = p_reservation AND status IN ('HELD','CONFIRMED');
END $$;

-- rpc_accept_offer promotes HELD -> CONFIRMED, which re-fires the sync trigger.
-- It needs the same trusted context. Row locking and every guard are unchanged.
CREATE OR REPLACE FUNCTION public.rpc_accept_offer(
  p_trip UUID, p_kirim UUID, p_idempotency_key TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  v_carrier UUID := authz.my_carrier_id();
  k public.kirim_requests; q internal.quotes;
  v_res UUID; v_delivery UUID; v_advance BIGINT;
BEGIN
  IF v_carrier IS NULL THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = p_kirim FOR UPDATE;
  IF NOT FOUND OR k.status <> 'POSTED' THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION';
  END IF;
  IF k.requester_id = auth.uid() THEN RAISE EXCEPTION 'SELF_DEALING'; END IF;

  v_advance := COALESCE(k.budget_cap_sen, 0);
  IF EXISTS (SELECT 1 FROM public.carriers c WHERE c.id = v_carrier
             AND c.cod_held_sen + c.procurement_advance_sen + v_advance > c.float_limit_sen)
  THEN RAISE EXCEPTION 'FLOAT_LIMIT_EXCEEDED'; END IF;

  v_res := internal.fn_reserve_capacity(
    p_trip, p_kirim, k.est_weight_grams, k.volume_cm3, 1);

  PERFORM set_config('kasihkirim.capacity_sync', 'on', true);
  UPDATE public.trip_reservations SET status='CONFIRMED', expires_at=NULL
   WHERE id = v_res;

  SELECT * INTO q FROM internal.quotes WHERE id = k.quote_id;

  INSERT INTO public.deliveries (kirim_id, trip_id, carrier_id, reservation_id,
    requester_id, status, cod_amount_sen, carrier_earning_sen, platform_fee_sen)
  VALUES (p_kirim, p_trip, v_carrier, v_res,
    k.requester_id, 'MATCHED',
    CASE WHEN k.payment_method='COD' THEN COALESCE(q.total_sen,0) ELSE 0 END,
    COALESCE(q.delivery_fee_sen,0) - COALESCE(q.commission_sen,0),
    COALESCE(q.commission_sen,0))
  RETURNING id INTO v_delivery;

  UPDATE public.carriers SET procurement_advance_sen = procurement_advance_sen + v_advance
   WHERE id = v_carrier;
  UPDATE public.kirim_requests SET status='MATCHED', updated_at=now() WHERE id=p_kirim;

  INSERT INTO public.delivery_events (delivery_id, from_status, to_status, event,
    actor_id, actor_role, source, idempotency_key)
  VALUES (v_delivery, 'POSTED','MATCHED','ACCEPT_OFFER', auth.uid(),'carrier','app',
          p_idempotency_key);

  RETURN jsonb_build_object('delivery_id', v_delivery, 'reservation_id', v_res,
                            'status','MATCHED');
END $$;

REVOKE ALL ON FUNCTION public.rpc_accept_offer(UUID,UUID,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_accept_offer(UUID,UUID,TEXT) TO authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- P0-2  RLS RECURSION
--
--   kirim_select ON kirim_requests -> EXISTS(... FROM deliveries ...)
--        -> deliveries_select      -> EXISTS(... FROM kirim_requests ...)
--             -> kirim_select      -> ... infinite
--
-- Broken by denormalising the requester onto deliveries, which makes
-- deliveries_select a LEAF policy: it no longer reads any RLS-protected table.
-- No SECURITY DEFINER, no RLS bypass, no new grants. The resulting visibility
-- is identical to the intent and strictly narrower than a bypass would be.
-- ════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.deliveries
  ADD COLUMN IF NOT EXISTS requester_id UUID REFERENCES public.profiles(id);

-- Backfill (no rows expected on a fresh database; correct on an existing one).
UPDATE public.deliveries d
   SET requester_id = k.requester_id
  FROM public.kirim_requests k
 WHERE k.id = d.kirim_id AND d.requester_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_deliveries_requester
  ON public.deliveries(requester_id);

-- A delivery belongs to exactly one kirim and never changes hands, so the
-- denormalised value is immutable. Enforce that rather than trusting callers.
CREATE OR REPLACE FUNCTION internal.tg_delivery_requester()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.requester_id IS NULL THEN
      SELECT k.requester_id INTO NEW.requester_id
        FROM public.kirim_requests k WHERE k.id = NEW.kirim_id;
    END IF;
  ELSIF NEW.requester_id IS DISTINCT FROM OLD.requester_id THEN
    RAISE EXCEPTION 'DELIVERY_REQUESTER_IMMUTABLE';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_deliveries_requester ON public.deliveries;
CREATE TRIGGER tg_deliveries_requester
  BEFORE INSERT OR UPDATE ON public.deliveries
  FOR EACH ROW EXECUTE FUNCTION internal.tg_delivery_requester();

-- deliveries_select becomes a leaf: no reference to any RLS-protected table.
DROP POLICY IF EXISTS deliveries_select ON public.deliveries;
CREATE POLICY deliveries_select ON public.deliveries FOR SELECT TO authenticated
  USING (carrier_id   = authz.my_carrier_id()
         OR requester_id = (SELECT auth.uid())
         OR authz.is_admin());

-- kirim_select is unchanged in meaning; its EXISTS on deliveries no longer
-- recurses because deliveries_select is now terminal.

-- ════════════════════════════════════════════════════════════════════════════
-- P1-3  CATEGORY COMPLIANCE DEFAULTS
--
-- 0007 populated ref.category_compliance with SELECT ... FROM ref.categories,
-- but categories are seeded in seed.sql, which runs AFTER migrations. The table
-- was therefore always empty on a fresh database.
--
-- A trigger removes the ordering dependency entirely: a category cannot exist
-- without a compliance row, whatever inserts it and whenever. Every row is born
-- CLOSED, so Muatan Jual stays off until compliance opens a category explicitly.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.tg_category_compliance_default()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  INSERT INTO ref.category_compliance
    (category_id, legal_status, requires_licence, requires_listing_approval,
     marketplace_enabled, legal_review_status, compliance_note)
  VALUES (NEW.id, 'APPROVAL_REQUIRED', false, true, false, 'PENDING',
          'Auto-created closed. MJ-04: determination pending. '
          'See docs/MUATAN-JUAL-COMPLIANCE.md §9.')
  ON CONFLICT (category_id) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_categories_compliance ON ref.categories;
CREATE TRIGGER tg_categories_compliance
  AFTER INSERT ON ref.categories
  FOR EACH ROW EXECUTE FUNCTION internal.tg_category_compliance_default();

-- Cover any category that already exists (e.g. re-running against a live DB).
INSERT INTO ref.category_compliance
  (category_id, legal_status, requires_licence, requires_listing_approval,
   marketplace_enabled, legal_review_status, compliance_note)
SELECT c.id, 'APPROVAL_REQUIRED', false, true, false, 'PENDING',
       'Backfilled closed. MJ-04: determination pending.'
FROM ref.categories c
ON CONFLICT (category_id) DO NOTHING;
