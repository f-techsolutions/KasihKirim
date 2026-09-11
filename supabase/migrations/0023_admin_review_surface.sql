-- ============================================================================
-- KasihKirim — 0023_admin_review_surface.sql
--
-- Closes the "queue with no way to clear it" gap that 0018 only half-closed.
-- 0018 added rpc_admin_set_product_status; nothing equivalent existed for a
-- seller application or a dispute, so approving a seller meant a raw UPDATE
-- on public.sellers plus a second, separate INSERT into public.user_roles --
-- two writes a human had to remember to keep in step, with no transaction
-- around them.
--
-- Deliberately NOT added here: read RPCs for the review queues. Admins can
-- already read every pending seller, product and dispute through existing
-- RLS -- sellers_select, products_select and disputes_select each carry an
-- `OR authz.is_admin()` clause (0003), and 0010 grants SELECT on all three
-- to authenticated. A queue-reader RPC would duplicate policy that is
-- already correct, and would have to be kept in step with it forever.
--
-- Refunds are recorded, not posted. Under the COD-first pilot
-- (MUATAN-JUAL-COMPLIANCE.md §8 q5, and ref.feature_gates'
-- prepaid_payments_enabled = false) the platform never holds the buyer's
-- money for a Jualan order, so there is nothing in internal.ledger_* to
-- reverse: refund_sen on the dispute row is the decision record, and the
-- money moves outside the platform. A real ledger refund leg belongs with
-- prepaid activation, not before it -- posting one now would credit a
-- refund against an escrow balance that was never funded.
-- ============================================================================

-- ── 1. Somewhere to put the reviewer's reason ────────────────────────────────
-- public.products already has rejection_reason (0016); sellers had no
-- equivalent, so a rejection could not tell the applicant what to fix.
ALTER TABLE public.sellers ADD COLUMN IF NOT EXISTS review_note TEXT;

-- ── 2. Seller application review ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_set_seller_status(
  p_seller_id UUID, p_status TEXT, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_seller public.sellers;
  v_status ref.verification_status;
  v_actor  UUID := (SELECT id FROM public.profiles WHERE id = (SELECT auth.uid()));
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_status NOT IN ('UNDER_REVIEW','MORE_INFO_REQUIRED','APPROVED',
                      'REJECTED','SUSPENDED','REVOKED') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;
  v_status := p_status::ref.verification_status;

  UPDATE public.sellers SET
    status      = v_status,
    review_note = COALESCE(p_reason, review_note),
    verified_at = CASE WHEN v_status = 'APPROVED'
                       THEN COALESCE(verified_at, now()) ELSE verified_at END,
    updated_at  = now()
  WHERE id = p_seller_id
  RETURNING * INTO v_seller;

  IF v_seller.id IS NULL THEN RAISE EXCEPTION 'SELLER_NOT_FOUND'; END IF;

  -- The status column and the role grant must move together. The client reads
  -- its role from the JWT (custom_access_token_hook, 0003), which is built
  -- from public.user_roles -- so an APPROVED sellers row with no role grant
  -- leaves the seller unable to reach a single seller screen, and a REVOKED
  -- row whose grant still stands leaves them able to reach all of them. Doing
  -- both in one function is the whole point of it existing.
  IF v_status = 'APPROVED' THEN
    INSERT INTO public.user_roles (user_id, role, granted_by)
    VALUES (v_seller.user_id, 'seller', v_actor)
    ON CONFLICT (user_id, role) DO UPDATE
      SET revoked_at = NULL, granted_at = now(), granted_by = v_actor;
  ELSIF v_status IN ('REJECTED','SUSPENDED','REVOKED') THEN
    UPDATE public.user_roles SET revoked_at = now()
     WHERE user_id = v_seller.user_id AND role = 'seller' AND revoked_at IS NULL;
  END IF;

  RETURN jsonb_build_object(
    'seller_id', v_seller.id,
    'status',    v_seller.status,
    -- The grant only reaches the seller's session when their token is next
    -- minted, so the console can tell them to sign in again.
    'role_active', v_status = 'APPROVED');
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_set_seller_status(UUID,TEXT,TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_set_seller_status(UUID,TEXT,TEXT)
  TO authenticated;

-- ── 3. Dispute resolution ────────────────────────────────────────────────────
-- fn_settle_delivery (0003) refuses to settle while any dispute on the
-- delivery has holds_escrow AND resolved_at IS NULL. Resolving a dispute is
-- therefore also what unblocks settlement -- which is why resolved_at is set
-- here rather than left for a second manual UPDATE.
CREATE OR REPLACE FUNCTION public.rpc_admin_resolve_dispute(
  p_dispute_id UUID, p_status TEXT,
  p_note TEXT DEFAULT NULL, p_refund_sen BIGINT DEFAULT 0)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_dispute public.disputes;
  v_status  ref.dispute_status;
  v_final   BOOLEAN;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF p_status NOT IN ('UNDER_REVIEW','AWAITING_EVIDENCE','DECIDED',
                      'RESOLVED_REFUND_FULL','RESOLVED_REFUND_PARTIAL',
                      'RESOLVED_REJECTED','RESOLVED_SPLIT','CLOSED') THEN
    RAISE EXCEPTION 'INVALID_STATUS';
  END IF;
  IF p_refund_sen < 0 THEN RAISE EXCEPTION 'INVALID_REFUND'; END IF;

  v_status := p_status::ref.dispute_status;
  v_final  := p_status LIKE 'RESOLVED\_%' OR p_status = 'CLOSED';

  UPDATE public.disputes SET
    status          = v_status,
    resolution_note = COALESCE(p_note, resolution_note),
    refund_sen      = CASE WHEN v_final THEN p_refund_sen ELSE refund_sen END,
    -- Clearing the escrow hold is what lets fn_settle_delivery run.
    holds_escrow    = CASE WHEN v_final THEN false ELSE holds_escrow END,
    resolved_by     = CASE WHEN v_final THEN (SELECT auth.uid()) ELSE resolved_by END,
    resolved_at     = CASE WHEN v_final THEN now() ELSE resolved_at END
  WHERE id = p_dispute_id
  RETURNING * INTO v_dispute;

  IF v_dispute.id IS NULL THEN RAISE EXCEPTION 'DISPUTE_NOT_FOUND'; END IF;

  RETURN jsonb_build_object(
    'dispute_id', v_dispute.id,
    'status',     v_dispute.status,
    'refund_sen', v_dispute.refund_sen,
    'resolved',   v_final);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_admin_resolve_dispute(UUID,TEXT,TEXT,BIGINT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_resolve_dispute(UUID,TEXT,TEXT,BIGINT)
  TO authenticated;
