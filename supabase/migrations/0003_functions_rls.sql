-- ============================================================================
-- KasihKirim — 0003_functions_rls.sql
-- The invariants that cannot be expressed as column constraints, plus policies.
-- ============================================================================

-- ════════════════════════════════════════════════════════════════════════════
-- AUTH HOOK  (helpers themselves live in 0000_prelude.sql)
-- ════════════════════════════════════════════════════════════════════════════
-- JWT enrichment: roles in the claim, not a join in every policy.
CREATE OR REPLACE FUNCTION auth.custom_access_token_hook(event jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_roles text[]; v_meta jsonb; v_uid uuid := (event->>'user_id')::uuid;
BEGIN
  SELECT array_agg(role::text) INTO v_roles
  FROM public.user_roles WHERE user_id = v_uid AND revoked_at IS NULL;

  SELECT jsonb_build_object(
    'roles', COALESCE(to_jsonb(v_roles),'[]'::jsonb),
    'carrier_id', (SELECT id FROM public.carriers WHERE user_id=v_uid AND status='APPROVED'),
    'seller_id',  (SELECT id FROM public.sellers  WHERE user_id=v_uid AND status='APPROVED'),
    'account_status', (SELECT status FROM public.profiles WHERE id=v_uid)
  ) INTO v_meta;

  RETURN jsonb_set(event,'{claims,app_metadata}',
    COALESCE(event->'claims'->'app_metadata','{}'::jsonb) || v_meta);
END $$;

-- Without these grants the hook runs but returns nothing, so every policy that
-- reads a role claim silently denies. Symptom: a logged-in user sees an empty
-- app with no error. Easy to misdiagnose for hours.
GRANT USAGE  ON SCHEMA public TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION auth.custom_access_token_hook(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION auth.custom_access_token_hook(jsonb) FROM authenticated, anon, public;
GRANT SELECT ON public.user_roles, public.carriers, public.sellers, public.profiles
  TO supabase_auth_admin;

-- The hook reads these tables directly; RLS must not filter it out.
CREATE POLICY auth_admin_read_roles ON public.user_roles
  FOR SELECT TO supabase_auth_admin USING (true);
CREATE POLICY auth_admin_read_carriers ON public.carriers
  FOR SELECT TO supabase_auth_admin USING (true);
CREATE POLICY auth_admin_read_sellers ON public.sellers
  FOR SELECT TO supabase_auth_admin USING (true);
CREATE POLICY auth_admin_read_profiles ON public.profiles
  FOR SELECT TO supabase_auth_admin USING (true);

-- ════════════════════════════════════════════════════════════════════════════
-- INVARIANT 1 — ledger always balances  (deferred to COMMIT)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.tg_assert_balanced()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_diff BIGINT;
BEGIN
  SELECT COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen ELSE -amount_sen END),0)
    INTO v_diff FROM internal.ledger_entries WHERE transaction_id = NEW.transaction_id;
  IF v_diff <> 0 THEN
    RAISE EXCEPTION 'Unbalanced ledger transaction %: debits-credits = % sen',
      NEW.transaction_id, v_diff USING ERRCODE='check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER tg_ledger_balanced
  AFTER INSERT ON internal.ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION internal.tg_assert_balanced();

-- ════════════════════════════════════════════════════════════════════════════
-- INVARIANT 2 — no overbooking  (BR-903)
-- Trigger recomputes reserved_*, which fires the CHECK constraints on trips.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.tg_sync_trip_reserved()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_trip UUID := COALESCE(NEW.trip_id, OLD.trip_id);
BEGIN
  UPDATE public.trips t SET
    reserved_weight_grams = COALESCE(a.w,0),
    reserved_volume_cm3   = COALESCE(a.v,0),
    reserved_parcels      = COALESCE(a.p,0),
    updated_at            = now()
  FROM (SELECT sum(weight_grams) w, sum(volume_cm3) v, sum(parcels) p
        FROM public.trip_reservations
        WHERE trip_id = v_trip AND status IN ('HELD','CONFIRMED','CONSUMED')) a
  WHERE t.id = v_trip;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER tg_trip_reserved_sync
  AFTER INSERT OR UPDATE OR DELETE ON public.trip_reservations
  DEFERRABLE INITIALLY IMMEDIATE
  FOR EACH ROW EXECUTE FUNCTION internal.tg_sync_trip_reserved();

-- The ONLY capacity writer. Row lock serialises concurrent bookings per trip.
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

  INSERT INTO public.trip_reservations
    (trip_id,kirim_id,status,weight_grams,volume_cm3,parcels,expires_at)
  VALUES (p_trip,p_kirim,'HELD',p_w,p_v,p_p, now() + (p_ttl_min||' minutes')::interval)
  RETURNING id INTO v_id;
  RETURN v_id;                    -- CHECK constraints fire via the trigger
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- INVARIANT 3 — budget cap  (BR-913)
-- Cannot be a CHECK: a legitimate overspend needs an approved variance.
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.tg_enforce_budget_cap()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
BEGIN
  IF NEW.kirim_type = 'BELI' AND NEW.actual_goods_sen IS NOT NULL
     AND NEW.actual_goods_sen > NEW.budget_cap_sen THEN
    IF NOT EXISTS (SELECT 1 FROM public.price_variances v
                   WHERE v.kirim_id = NEW.id AND v.status = 'APPROVED'
                     AND v.approved_amount_sen >= NEW.actual_goods_sen) THEN
      RAISE EXCEPTION
        'BR-913: goods cost % exceeds budget cap % without an approved variance',
        NEW.actual_goods_sen, NEW.budget_cap_sen USING ERRCODE='check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER tg_kirim_budget_cap
  BEFORE INSERT OR UPDATE OF actual_goods_sen ON public.kirim_requests
  FOR EACH ROW EXECUTE FUNCTION internal.tg_enforce_budget_cap();

-- ════════════════════════════════════════════════════════════════════════════
-- INVARIANT 4 — protected profile columns
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.tg_protect_profile_columns()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF auth.is_admin() THEN RETURN NEW; END IF;
  NEW.status := OLD.status;
  NEW.rating_avg := OLD.rating_avg;
  NEW.rating_count := OLD.rating_count;
  NEW.kirim_sent_count := OLD.kirim_sent_count;
  NEW.kirim_received_count := OLD.kirim_received_count;
  NEW.phone := OLD.phone;
  NEW.nric_hash := OLD.nric_hash;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_profiles_protect BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION internal.tg_protect_profile_columns();

-- Trips: capacity columns are not user-editable.
CREATE OR REPLACE FUNCTION internal.tg_protect_trip_capacity()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF auth.is_admin() THEN RETURN NEW; END IF;
  NEW.reserved_weight_grams := OLD.reserved_weight_grams;
  NEW.reserved_volume_cm3   := OLD.reserved_volume_cm3;
  NEW.reserved_parcels      := OLD.reserved_parcels;
  IF OLD.status <> 'DRAFT' THEN
    NEW.capacity_weight_grams := OLD.capacity_weight_grams;
    NEW.capacity_volume_cm3   := OLD.capacity_volume_cm3;
    NEW.capacity_parcels      := OLD.capacity_parcels;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_trips_protect BEFORE UPDATE ON public.trips
  FOR EACH ROW EXECUTE FUNCTION internal.tg_protect_trip_capacity();

-- ════════════════════════════════════════════════════════════════════════════
-- PRICING  (BR-900 — server only; band-based, not per-km)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_band_for(p_km NUMERIC, p JSONB)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_km <= (p->'corridor_band_km'->>'local')::numeric    THEN 'local'
    WHEN p_km <= (p->'corridor_band_km'->>'district')::numeric THEN 'district'
    WHEN p_km <= (p->'corridor_band_km'->>'regional')::numeric THEN 'regional'
    ELSE 'long_haul' END;
$$;

CREATE OR REPLACE FUNCTION internal.fn_quote_kirim(
  p_type ref.kirim_type, p_category UUID, p_weight_g INT, p_volume_cm3 INT,
  p_budget_sen BIGINT, p_origin UUID, p_dest UUID,
  p_flags ref.handling_flag[], p_method ref.payment_method, p_requester UUID)
RETURNS internal.quotes LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
  r internal.pricing_rules; p JSONB; km NUMERIC; band TEXT;
  base BIGINT; bandfee BIGINT; wfee BIGINT; hfee BIGINT := 0; codfee BIGINT := 0;
  billable_kg NUMERIC; delivery BIGINT; goods BIGINT; total BIGINT;
  comm BIGINT; crule internal.commission_rules; f ref.handling_flag; q internal.quotes;
BEGIN
  SELECT * INTO r FROM internal.pricing_rules
   WHERE effective_from <= now() AND (effective_to IS NULL OR effective_to > now())
   ORDER BY version DESC LIMIT 1;
  p := r.params;

  SELECT distance_km INTO km FROM ref.node_distance_matrix
   WHERE from_node_id = p_origin AND to_node_id = p_dest;
  km := COALESCE(km, 50);
  band := internal.fn_band_for(km, p);

  billable_kg := GREATEST(p_weight_g/1000.0,
                          p_volume_cm3::numeric / (p->>'volumetric_divisor')::numeric);
  base    := (p->>'base_fare_sen')::bigint;
  bandfee := (p->'corridor_band_sen'->>band)::bigint;
  wfee    := CEIL(GREATEST(0, billable_kg - (p->>'included_kg')::numeric))
             * (p->>'per_kg_sen')::bigint;
  FOREACH f IN ARRAY p_flags LOOP
    hfee := hfee + COALESCE((p->'handling_surcharge_sen'->>f::text)::bigint, 0);
  END LOOP;
  IF p_method = 'COD' THEN codfee := (p->>'cod_handling_sen')::bigint; END IF;

  delivery := base + bandfee + wfee + hfee + codfee;
  goods    := CASE WHEN p_type='BELI' THEN COALESCE(p_budget_sen,0) ELSE 0 END;
  total    := goods + delivery;

  SELECT * INTO crule FROM internal.commission_rules
   WHERE party='platform' AND effective_from <= now()
     AND (effective_to IS NULL OR effective_to > now()) ORDER BY effective_from DESC LIMIT 1;

  comm := CASE crule.basis
            WHEN 'order_total'  THEN total * crule.rate_bps / 10000
            WHEN 'delivery_fee' THEN delivery * crule.rate_bps / 10000
            WHEN 'goods_subtotal' THEN goods * crule.rate_bps / 10000
            ELSE crule.flat_sen END;
  IF crule.max_commission_sen IS NOT NULL THEN
    comm := LEAST(comm, crule.max_commission_sen);
  END IF;

  INSERT INTO internal.quotes (subject_type, requester_id, input_snapshot, breakdown,
    goods_budget_sen, delivery_fee_sen, commission_sen, total_sen,
    pricing_rule_version, corridor_km, corridor_band, expires_at)
  VALUES ('kirim', p_requester,
    jsonb_build_object('type',p_type,'weight_g',p_weight_g,'budget',p_budget_sen,
                       'origin',p_origin,'dest',p_dest,'flags',p_flags),
    jsonb_build_object('base',base,'band',bandfee,'band_name',band,'weight',wfee,
                       'handling',hfee,'cod',codfee),
    goods, delivery, comm, total, r.version, km, band,
    now() + ((SELECT (value#>>'{}')::int FROM ref.app_config WHERE key='quote_ttl_minutes')
             ||' minutes')::interval)
  RETURNING * INTO q;
  RETURN q;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- SETTLEMENT  (BR-915 — unspent budget always returns)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_settle_delivery(p_delivery UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.deliveries; k public.kirim_requests; q internal.quotes;
        v_txn UUID; v_actual BIGINT; v_refund BIGINT;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id=p_delivery FOR UPDATE;
  SELECT * INTO k FROM public.kirim_requests WHERE id=d.kirim_id;
  SELECT * INTO q FROM internal.quotes WHERE id=k.quote_id;

  IF EXISTS (SELECT 1 FROM public.disputes
             WHERE delivery_id=p_delivery AND holds_escrow AND resolved_at IS NULL) THEN
    RAISE EXCEPTION 'ESCROW_HELD_BY_DISPUTE';
  END IF;

  v_actual := COALESCE(k.actual_goods_sen, 0);
  v_refund := q.goods_budget_sen - v_actual;
  IF v_refund < 0 THEN RAISE EXCEPTION 'BR-915 VIOLATION: refund would be negative'; END IF;

  INSERT INTO internal.ledger_transactions (kind, reference_type, reference_id, idempotency_key, description)
  VALUES ('SETTLEMENT','delivery',p_delivery,'settle:'||p_delivery::text,'Settlement '||k.reference_code)
  RETURNING id INTO v_txn;

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

  UPDATE public.deliveries SET status='COMPLETED', completed_at=now() WHERE id=p_delivery;
  UPDATE public.kirim_requests SET status='COMPLETED' WHERE id=k.id;
  UPDATE public.carriers
     SET procurement_advance_sen = GREATEST(0, procurement_advance_sen - v_actual),
         completed_count = completed_count + 1
   WHERE id = d.carrier_id;
END $$;

-- Helper: resolve-or-create an account and post one entry.
CREATE OR REPLACE FUNCTION internal.fn_post(
  p_txn UUID, p_code TEXT, p_dir ref.ledger_direction, p_amount BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_acct UUID;
BEGIN
  IF p_amount = 0 THEN RETURN; END IF;
  SELECT id INTO v_acct FROM internal.ledger_accounts WHERE account_code = p_code;
  IF NOT FOUND THEN
    INSERT INTO internal.ledger_accounts (account_code, account_class, is_system)
    VALUES (p_code,
      CASE WHEN p_code LIKE 'PLATFORM_%' THEN 'REVENUE'
           WHEN p_code LIKE 'ESCROW_%' OR p_code LIKE '%PAYABLE%' OR p_code LIKE '%REFUND%'
             THEN 'LIABILITY' ELSE 'ASSET' END::ref.account_class,
      p_code NOT LIKE '%:%')
    RETURNING id INTO v_acct;
  END IF;
  INSERT INTO internal.ledger_entries (transaction_id, account_id, direction, amount_sen)
  VALUES (p_txn, v_acct, p_dir, p_amount);
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- DELIVERY STATE MACHINE  (BR-904 — the only writer of deliveries.status)
-- ════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION internal.fn_delivery_transition(
  p_delivery UUID, p_event TEXT, p_actor UUID, p_role ref.user_role,
  p_idem TEXT DEFAULT NULL, p_meta JSONB DEFAULT '{}')
RETURNS ref.kirim_status LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE d public.deliveries; k public.kirim_requests; rule ref.delivery_transition_rules;
BEGIN
  IF p_idem IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.delivery_events WHERE idempotency_key = p_idem) THEN
    SELECT status INTO d.status FROM public.deliveries WHERE id=p_delivery;
    RETURN d.status;                                   -- replay: no second effect
  END IF;

  SELECT * INTO d FROM public.deliveries WHERE id=p_delivery FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  SELECT * INTO k FROM public.kirim_requests WHERE id=d.kirim_id;

  SELECT * INTO rule FROM ref.delivery_transition_rules
   WHERE from_status=d.status AND event=p_event;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION: % from %', p_event, d.status;
  END IF;
  IF NOT (p_role = ANY(rule.allowed_roles)) THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;
  IF NOT (k.kirim_type = ANY(rule.applies_to_types)) THEN
    RAISE EXCEPTION 'STATE_INVALID_TRANSITION: not applicable to %', k.kirim_type;
  END IF;

  UPDATE public.deliveries SET
    status = rule.to_status,
    picked_up_at  = CASE WHEN rule.to_status='PICKED_UP' THEN now() ELSE picked_up_at END,
    delivered_at  = CASE WHEN rule.to_status='DELIVERED' THEN now() ELSE delivered_at END,
    recipient_confirmed_at = CASE WHEN p_event='CONFIRM_RECEIPT' THEN now()
                                  ELSE recipient_confirmed_at END,
    settlement_due_at = CASE WHEN rule.to_status='DELIVERED'
      THEN now() + ((SELECT (value#>>'{}')::int FROM ref.app_config
                     WHERE key='settlement_window_hours')||' hours')::interval
      ELSE settlement_due_at END,
    updated_at = now()
  WHERE id = p_delivery;

  UPDATE public.kirim_requests SET status=rule.to_status, updated_at=now() WHERE id=k.id;

  INSERT INTO public.delivery_events
    (delivery_id, from_status, to_status, event, actor_id, actor_role, source,
     idempotency_key, metadata)
  VALUES (p_delivery, d.status, rule.to_status, p_event, p_actor, p_role,
          CASE WHEN p_role::text LIKE 'admin\_%' THEN 'admin' ELSE 'app' END,
          p_idem, p_meta);

  -- BR-907: recipient confirmation is the primary escrow release trigger.
  IF p_event = 'CONFIRM_RECEIPT' THEN
    PERFORM internal.fn_settle_delivery(p_delivery);
  END IF;

  RETURN rule.to_status;
END $$;

-- ════════════════════════════════════════════════════════════════════════════
-- ROW LEVEL SECURITY — default deny everywhere
-- ════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE t RECORD;
BEGIN
  -- Extension-owned tables (PostGIS spatial_ref_sys, pg_cron) live in public
  -- but are not ours. ALTER on them fails and aborts the migration.
  FOR t IN
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'e'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND d.objid IS NULL                       -- not owned by an extension
      AND c.relname NOT IN ('spatial_ref_sys')
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.relname);
  END LOOP;
END $$;

-- profiles
CREATE POLICY profiles_select ON public.profiles FOR SELECT TO authenticated
  USING (id = (SELECT auth.uid()) OR auth.is_admin());
CREATE POLICY profiles_update ON public.profiles FOR UPDATE TO authenticated
  USING (id = (SELECT auth.uid())) WITH CHECK (id = (SELECT auth.uid()));

-- Public projection for counterparties: name + rating only, never phone.
CREATE VIEW public.v_public_profiles WITH (security_barrier=true) AS
  SELECT id, display_name, avatar_path, rating_avg, rating_count,
         kirim_sent_count, kirim_received_count
  FROM public.profiles WHERE deleted_at IS NULL AND status='active';
GRANT SELECT ON public.v_public_profiles TO authenticated;

-- addresses / devices / community_members / user_badges: own only
CREATE POLICY addresses_own ON public.addresses FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY devices_own ON public.devices FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY cmembers_own ON public.community_members FOR ALL TO authenticated
  USING (user_id = (SELECT auth.uid())) WITH CHECK (user_id = (SELECT auth.uid()));
CREATE POLICY badges_read ON public.user_badges FOR SELECT TO authenticated USING (true);

CREATE POLICY communities_read ON public.communities FOR SELECT TO authenticated USING (is_active);

-- carriers / vehicles
CREATE POLICY carriers_select ON public.carriers FOR SELECT TO authenticated
  USING (user_id = (SELECT auth.uid()) OR status='APPROVED' OR auth.is_admin());
CREATE POLICY vehicles_own ON public.vehicles FOR ALL TO authenticated
  USING (carrier_id = auth.my_carrier_id()) WITH CHECK (carrier_id = auth.my_carrier_id());

-- trips: own, plus the public board
CREATE POLICY trips_select ON public.trips FOR SELECT TO authenticated
  USING (carrier_id = auth.my_carrier_id()
         OR status IN ('ANNOUNCED','BOARDING') OR auth.is_admin());
CREATE POLICY trips_insert ON public.trips FOR INSERT TO authenticated
  WITH CHECK (carrier_id = auth.my_carrier_id());
CREATE POLICY trips_update ON public.trips FOR UPDATE TO authenticated
  USING (carrier_id = auth.my_carrier_id() AND status <> 'DEPARTED')
  WITH CHECK (carrier_id = auth.my_carrier_id());

-- kirim: own + board. Carriers see the item, NOT the requester's contact details.
CREATE POLICY kirim_select ON public.kirim_requests FOR SELECT TO authenticated
  USING (
    requester_id = (SELECT auth.uid())
    OR (status='POSTED' AND visibility='board' AND deleted_at IS NULL AND auth.has_role('carrier'))
    OR EXISTS (SELECT 1 FROM public.deliveries d
               WHERE d.kirim_id = kirim_requests.id AND d.carrier_id = auth.my_carrier_id())
    OR auth.is_admin());
CREATE POLICY kirim_insert ON public.kirim_requests FOR INSERT TO authenticated
  WITH CHECK (requester_id = (SELECT auth.uid()) AND status='DRAFT');
CREATE POLICY kirim_update_draft ON public.kirim_requests FOR UPDATE TO authenticated
  USING (requester_id = (SELECT auth.uid()) AND status='DRAFT')
  WITH CHECK (requester_id = (SELECT auth.uid()) AND status='DRAFT');

-- deliveries: read-only to counterparties. NO write policy exists. (BR-904)
CREATE POLICY deliveries_select ON public.deliveries FOR SELECT TO authenticated
  USING (carrier_id = auth.my_carrier_id()
         OR EXISTS (SELECT 1 FROM public.kirim_requests k
                    WHERE k.id = deliveries.kirim_id AND k.requester_id = (SELECT auth.uid()))
         OR auth.is_admin());

CREATE POLICY devents_select ON public.delivery_events FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.deliveries d
                 WHERE d.id = delivery_events.delivery_id
                   AND (d.carrier_id = auth.my_carrier_id()
                        OR EXISTS (SELECT 1 FROM public.kirim_requests k
                                   WHERE k.id=d.kirim_id AND k.requester_id=(SELECT auth.uid())))));

CREATE POLICY reservations_select ON public.trip_reservations FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.trips t
                 WHERE t.id = trip_reservations.trip_id AND t.carrier_id = auth.my_carrier_id())
         OR EXISTS (SELECT 1 FROM public.kirim_requests k
                    WHERE k.id = trip_reservations.kirim_id AND k.requester_id=(SELECT auth.uid())));

CREATE POLICY variances_select ON public.price_variances FOR SELECT TO authenticated
  USING (raised_by = (SELECT auth.uid())
         OR EXISTS (SELECT 1 FROM public.kirim_requests k
                    WHERE k.id = price_variances.kirim_id AND k.requester_id=(SELECT auth.uid()))
         OR auth.is_admin());

-- handover_codes: NEVER readable by anyone. No SELECT policy at all.
REVOKE ALL ON public.handover_codes FROM authenticated, anon;

CREATE POLICY proofs_select ON public.proofs FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.deliveries d
                 WHERE d.id = proofs.delivery_id
                   AND (d.carrier_id = auth.my_carrier_id()
                        OR EXISTS (SELECT 1 FROM public.kirim_requests k
                                   WHERE k.id=d.kirim_id AND k.requester_id=(SELECT auth.uid())))));

-- marketplace
CREATE POLICY products_select ON public.products FOR SELECT TO authenticated
  USING (status='active' AND deleted_at IS NULL
         OR seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid()))
         OR auth.is_admin());
CREATE POLICY products_write ON public.products FOR ALL TO authenticated
  USING (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid())))
  WITH CHECK (seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid())));
CREATE POLICY product_images_read ON public.product_images FOR SELECT TO authenticated USING (true);
CREATE POLICY sellers_select ON public.sellers FOR SELECT TO authenticated
  USING (status='APPROVED' OR user_id=(SELECT auth.uid()) OR auth.is_admin());
CREATE POLICY inventory_own ON public.inventory FOR SELECT TO authenticated
  USING (product_id IN (SELECT p.id FROM public.products p
                        JOIN public.sellers s ON s.id=p.seller_id
                        WHERE s.user_id=(SELECT auth.uid())));

CREATE POLICY orders_select ON public.orders FOR SELECT TO authenticated
  USING (buyer_id=(SELECT auth.uid())
         OR seller_id IN (SELECT id FROM public.sellers WHERE user_id=(SELECT auth.uid()))
         OR auth.is_admin());
CREATE POLICY order_items_select ON public.order_items FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.orders o WHERE o.id=order_items.order_id
                 AND (o.buyer_id=(SELECT auth.uid())
                      OR o.seller_id IN (SELECT id FROM public.sellers
                                         WHERE user_id=(SELECT auth.uid())))));

-- vouchers, reviews, chat, notifications
CREATE POLICY vouchers_own ON public.voucher_issuances FOR SELECT TO authenticated
  USING (user_id=(SELECT auth.uid()));
CREATE POLICY campaigns_read ON public.voucher_campaigns FOR SELECT TO authenticated
  USING (is_active AND now() BETWEEN starts_at AND ends_at);

CREATE POLICY reviews_select ON public.reviews FOR SELECT TO authenticated
  USING (is_visible OR rater_id=(SELECT auth.uid()) OR auth.is_admin());
CREATE POLICY reviews_insert ON public.reviews FOR INSERT TO authenticated
  WITH CHECK (rater_id=(SELECT auth.uid())
    AND EXISTS (SELECT 1 FROM public.deliveries d
                WHERE d.id=reviews.delivery_id AND d.status='COMPLETED'));

CREATE POLICY disputes_select ON public.disputes FOR SELECT TO authenticated
  USING (raised_by=(SELECT auth.uid()) OR against_id=(SELECT auth.uid()) OR auth.is_admin());

CREATE POLICY conv_select ON public.conversations FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.conversation_participants cp
                 WHERE cp.conversation_id=conversations.id AND cp.user_id=(SELECT auth.uid())));
CREATE POLICY parts_select ON public.conversation_participants FOR SELECT TO authenticated
  USING (user_id=(SELECT auth.uid()));
CREATE POLICY messages_select ON public.messages FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.conversation_participants cp
                 WHERE cp.conversation_id=messages.conversation_id
                   AND cp.user_id=(SELECT auth.uid())));
CREATE POLICY messages_insert ON public.messages FOR INSERT TO authenticated
  WITH CHECK (sender_id=(SELECT auth.uid())
    AND EXISTS (SELECT 1 FROM public.conversation_participants cp
                WHERE cp.conversation_id=messages.conversation_id
                  AND cp.user_id=(SELECT auth.uid())));

CREATE POLICY notifications_own ON public.notifications FOR SELECT TO authenticated
  USING (user_id=(SELECT auth.uid()));
CREATE POLICY notifications_read ON public.notifications FOR UPDATE TO authenticated
  USING (user_id=(SELECT auth.uid())) WITH CHECK (user_id=(SELECT auth.uid()));

GRANT SELECT ON ALL TABLES IN SCHEMA ref TO authenticated;
