-- ============================================================================
-- KasihKirim — 0018_admin_product_review.sql
--
-- Found writing supabase/tests/13_seller_onboarding.test.sql's own "admin
-- can approve a product" case: products_write (pre-existing RLS, confirmed
-- live) is seller-own-row only --
--   seller_id IN (SELECT id FROM sellers WHERE user_id = auth.uid())
-- -- with no OR authz.is_admin() clause at all, unlike products_select.
-- Combined with 0016/0017's own moderation-column trigger (which correctly
-- refuses a seller's own attempt to self-approve), the result is that
-- NOTHING could ever move a product from pending_review to active through
-- PostgREST: the seller is trigger-blocked, and admin was RLS-blocked
-- before even reaching the trigger. A queue with no way to clear it.
--
-- This does not touch products_write -- broadening a seller-scoped RLS
-- policy to admins is a bigger, separate decision than this migration's
-- job. Instead, a narrow SECURITY DEFINER RPC gives admin_ops exactly the
-- write FR-271 ("admin verification with tiers") requires, nothing wider.
-- No Android UI calls this -- the admin console is a separate Next.js app
-- (docs/PRD.md's own platform table), out of this app's scope entirely.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_admin_set_product_status(
  p_product_id UUID, p_status TEXT,
  p_rejection_reason TEXT DEFAULT NULL, p_compliance_note TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE v_product public.products;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;
  IF p_status NOT IN ('active','rejected','paused','delisted') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;

  UPDATE public.products SET
    status = p_status,
    approved_by = CASE WHEN p_status = 'active' THEN (SELECT auth.uid()) ELSE approved_by END,
    approved_at = CASE WHEN p_status = 'active' THEN now() ELSE approved_at END,
    rejection_reason = CASE WHEN p_status = 'rejected' THEN p_rejection_reason ELSE rejection_reason END,
    compliance_note = COALESCE(p_compliance_note, compliance_note),
    updated_at = now()
  WHERE id = p_product_id
  RETURNING * INTO v_product;

  IF v_product.id IS NULL THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;

  RETURN jsonb_build_object('id', v_product.id, 'status', v_product.status);
END;
$function$;

REVOKE ALL ON FUNCTION
  public.rpc_admin_set_product_status(UUID,TEXT,TEXT,TEXT)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION
  public.rpc_admin_set_product_status(UUID,TEXT,TEXT,TEXT)
TO authenticated;
