-- ============================================================================
-- KasihKirim — 0036_carrier_board_marketplace_cod_visibility.sql   (P2-D)
--
-- PHASE 2 carrier flow. Found inspecting the existing board before extending
-- it: a PASARAN kirim posted to the board carries delivery_fee_sen (the
-- carriage leg alone, e.g. RM5) as its only money figure, the same as a
-- HANTAR job. But rpc_accept_offer (0027) makes a carrier who accepts a
-- PASARAN offer collect the WHOLE order via COD -- goods and carriage
-- together (v_cod := orders.total_sen, e.g. RM40) -- the moment they accept.
-- A carrier browsing the board today has no way to see that larger figure
-- before committing: kirim_requests carries no such column, and orders_select
-- (0003) does not grant a browsing (not-yet-assigned) carrier any read on
-- public.orders at all, so a plain embed/join through PostgREST is refused by
-- RLS exactly as it should be.
--
-- rpc_board() is the read-only fix, the same shape as 0034/0035's own narrow
-- SECURITY DEFINER functions: it returns exactly the rows kirim_select's own
-- board clause already exposes to any carrier (status='POSTED' AND
-- visibility='board' AND deleted_at IS NULL, restricted here to a caller who
-- actually holds the carrier role -- kirim_select's own board clause has the
-- same requirement), plus one extra derived figure. It does not let a carrier
-- see anything about an order they have not accepted beyond the one number
-- they would learn anyway the instant they DID accept (deliveries.cod_amount_sen
-- is not RLS-protected from them once assigned) -- this only moves that
-- disclosure earlier, to before the commitment. orders_select itself is
-- unchanged: a carrier still cannot read public.orders directly.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_board()
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path='' AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC), '[]'::jsonb)
  FROM (
    SELECT
      k.id, k.reference_code, k.kirim_type, k.status, k.item_description,
      k.est_weight_grams, k.origin_node_id, k.dest_node_id,
      k.budget_cap_sen, k.delivery_fee_sen, k.commission_sen, k.created_at,
      -- The full COD collection amount for a marketplace order -- goods plus
      -- carriage, exactly what rpc_accept_offer will actually charge the
      -- carrier to collect. NULL for BELI/HANTAR, which have no linked order.
      CASE WHEN k.kirim_type = 'PASARAN' THEN o.total_sen ELSE NULL END AS cod_total_sen
    FROM public.kirim_requests k
    LEFT JOIN public.orders o ON o.id = k.order_id
    WHERE k.status = 'POSTED' AND k.visibility = 'board' AND k.deleted_at IS NULL
      AND authz.has_role('carrier')
  ) t;
$$;

REVOKE ALL ON FUNCTION public.rpc_board() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_board() TO authenticated;

COMMENT ON FUNCTION public.rpc_board() IS
  'Read-only. Same rows kirim_select''s own board clause already grants a '
  'carrier, plus cod_total_sen for a PASARAN listing -- the true COD amount '
  'rpc_accept_offer will charge them to collect, visible before they accept '
  'rather than only after. Returns an empty array for a non-carrier caller, '
  'the same as the plain board select already does under RLS.';
