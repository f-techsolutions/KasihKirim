-- ============================================================================
-- KasihKirim — 0046_live_delivery_tracking.sql
--
-- Phase 2's last item: a customer can watch their carrier's position update
-- live between pickup and drop-off, instead of only seeing a status word.
--
-- ── Design ───────────────────────────────────────────────────────────────
--   * One row per delivery (public.delivery_locations), upserted -- this is
--     "where is my carrier right now", not a route history/breadcrumb trail.
--     A future "replay the route" feature would need a real log table; this
--     one is deliberately not it (mirrors proofs' own one-row-per-leg shape,
--     not delivery_events' append-only log).
--   * carrier_id/requester_id are denormalized onto the row from the
--     delivery itself (copied at write time), the same reason
--     public.deliveries carries its own requester_id instead of a client
--     having to join through kirim_requests for RLS -- a flat predicate,
--     and Supabase Realtime's own postgres_changes filter
--     (delivery_id=eq.<id>) needs no join to decide who may see a row.
--   * Only writable while the delivery is actually being carried
--     (PICKED_UP through OUT_FOR_DELIVERY -- ref.delivery_transition_rules'
--     own chain, seed.sql). Before pickup there is nothing to watch; after
--     DELIVERED the customer has the parcel already. This is also a privacy
--     boundary: a carrier's live position is only ever exposed for the
--     specific window a specific customer has a real reason to see it.
--   * Realtime is added to this table (not proxied through a channel a
--     client has to be granted separately) -- Supabase Realtime enforces
--     the table's own RLS per subscriber, so the same policy that gates a
--     plain SELECT also gates what a postgres_changes stream delivers.
-- ============================================================================

CREATE TABLE public.delivery_locations (
  delivery_id   UUID PRIMARY KEY REFERENCES public.deliveries(id) ON DELETE CASCADE,
  carrier_id    UUID NOT NULL REFERENCES public.carriers(id),
  requester_id  UUID NOT NULL REFERENCES public.profiles(id),
  geog          GEOGRAPHY(POINT,4326) NOT NULL,
  heading_deg   NUMERIC(5,1) CHECK (heading_deg IS NULL OR heading_deg BETWEEN 0 AND 360),
  speed_kmh     NUMERIC(6,1) CHECK (speed_kmh IS NULL OR speed_kmh >= 0),
  accuracy_m    NUMERIC(7,1) CHECK (accuracy_m IS NULL OR accuracy_m >= 0),
  recorded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_delivery_locations_carrier ON public.delivery_locations(carrier_id);

ALTER TABLE public.delivery_locations ENABLE ROW LEVEL SECURITY;

-- Same predicate as public.deliveries' own deliveries_select policy --
-- whoever may see the delivery may watch it move.
CREATE POLICY delivery_locations_select ON public.delivery_locations FOR SELECT TO authenticated
  USING (carrier_id = authz.my_carrier_id()
         OR requester_id = (SELECT auth.uid())
         OR authz.is_admin());
REVOKE INSERT, UPDATE, DELETE ON public.delivery_locations FROM authenticated, anon;

ALTER PUBLICATION supabase_realtime ADD TABLE public.delivery_locations;

/** The only write path. Upserts this delivery's current position -- mirrors
 *  rpc_submit_proof's own ON CONFLICT DO UPDATE shape (0014) and its
 *  public.ST_MakePoint(lng, lat)::public.geography construction. */
CREATE OR REPLACE FUNCTION public.rpc_update_delivery_location(
  p_delivery UUID, p_lat DOUBLE PRECISION, p_lng DOUBLE PRECISION,
  p_heading_deg NUMERIC DEFAULT NULL, p_speed_kmh NUMERIC DEFAULT NULL,
  p_accuracy_m NUMERIC DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE d public.deliveries;
BEGIN
  IF p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'INVALID_COORDINATES';
  END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  IF NOT EXISTS (SELECT 1 FROM public.carriers c
                 WHERE c.id = d.carrier_id AND c.user_id = (SELECT auth.uid())) THEN
    RAISE EXCEPTION 'NOT_ASSIGNED_CARRIER';
  END IF;

  IF d.status NOT IN ('PICKED_UP','IN_TRANSIT','AT_HUB','OUT_FOR_DELIVERY') THEN
    RAISE EXCEPTION 'DELIVERY_NOT_IN_TRANSIT';
  END IF;

  INSERT INTO public.delivery_locations
    (delivery_id, carrier_id, requester_id, geog, heading_deg, speed_kmh, accuracy_m, recorded_at)
  VALUES
    (p_delivery, d.carrier_id, d.requester_id,
     public.ST_MakePoint(p_lng, p_lat)::public.geography,
     p_heading_deg, p_speed_kmh, p_accuracy_m, now())
  ON CONFLICT (delivery_id) DO UPDATE SET
    geog        = EXCLUDED.geog,
    heading_deg = EXCLUDED.heading_deg,
    speed_kmh   = EXCLUDED.speed_kmh,
    accuracy_m  = EXCLUDED.accuracy_m,
    recorded_at = EXCLUDED.recorded_at;
END $$;

REVOKE ALL ON FUNCTION
  public.rpc_update_delivery_location(UUID,DOUBLE PRECISION,DOUBLE PRECISION,NUMERIC,NUMERIC,NUMERIC)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.rpc_update_delivery_location(UUID,DOUBLE PRECISION,DOUBLE PRECISION,NUMERIC,NUMERIC,NUMERIC)
  TO authenticated;

/** One-shot read for a tracking screen's initial render -- the carrier's
 *  last known position (if any) plus the delivery's origin/destination
 *  route nodes, so a map can be bounded before the first Realtime event
 *  arrives. Ownership is enforced here the same way delivery_locations'
 *  own RLS does it, since a delivery with no location row yet would
 *  otherwise return nothing to check a policy against. */
CREATE OR REPLACE FUNCTION public.rpc_get_delivery_tracking(p_delivery UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d public.deliveries; k public.kirim_requests;
  loc public.delivery_locations;
  v_origin JSONB; v_dest JSONB;
BEGIN
  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;

  IF d.carrier_id <> authz.my_carrier_id()
     AND d.requester_id <> (SELECT auth.uid())
     AND NOT authz.is_admin() THEN
    RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED';
  END IF;

  SELECT * INTO k FROM public.kirim_requests WHERE id = d.kirim_id;

  SELECT jsonb_build_object('name', n.name, 'lat', ST_Y(n.geog::geometry), 'lng', ST_X(n.geog::geometry))
    INTO v_origin FROM ref.route_nodes n WHERE n.id = k.origin_node_id;
  SELECT jsonb_build_object('name', n.name, 'lat', ST_Y(n.geog::geometry), 'lng', ST_X(n.geog::geometry))
    INTO v_dest FROM ref.route_nodes n WHERE n.id = k.dest_node_id;

  SELECT * INTO loc FROM public.delivery_locations WHERE delivery_id = p_delivery;

  RETURN jsonb_build_object(
    'delivery_status', d.status::text,
    'origin', v_origin,
    'destination', v_dest,
    'carrier_location', CASE WHEN loc.delivery_id IS NULL THEN NULL ELSE
      jsonb_build_object(
        'lat', ST_Y(loc.geog::geometry), 'lng', ST_X(loc.geog::geometry),
        'heading_deg', loc.heading_deg, 'speed_kmh', loc.speed_kmh,
        'accuracy_m', loc.accuracy_m, 'recorded_at', loc.recorded_at)
    END);
END $$;

REVOKE ALL ON FUNCTION public.rpc_get_delivery_tracking(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_get_delivery_tracking(UUID) TO authenticated;
