-- ============================================================================
-- KasihKirim — 0042_carrier_seller_payouts.sql
--
-- Phase 1, third and final item: withdrawals. internal.bank_accounts and
-- internal.payouts have existed since 0001 with a maker-checker constraint
-- already in place (ck_payout_segregation: approved_by <> reviewed_by) --
-- but grep across every migration through 0041 confirms nothing has ever
-- written to either table. A carrier or seller with a real ledger balance
-- (rpc_my_earnings, 0029) has had no way to actually withdraw it.
--
-- SCOPE, per product decision: this is the internal flow only. Nothing here
-- calls a real disbursement rail -- rpc_admin_mark_payout_paid records that
-- an admin sent the money (by whatever manual/offline means), it does not
-- send it. A future migration can point PROCESSING/BATCHED at a real
-- provider without touching the request/review/approve steps below.
--
-- Flow: rpc_request_withdrawal (REQUESTED) -> rpc_admin_review_payout
-- (UNDER_REVIEW or REJECTED) -> rpc_admin_approve_payout (APPROVED or
-- REJECTED, by a different admin -- ck_payout_segregation) ->
-- rpc_admin_mark_payout_paid (PAID, the only step that posts to the ledger)
-- or rpc_admin_mark_payout_failed (FAILED). BATCHED/PROCESSING are left
-- unused for now -- they belong to whatever real provider integration comes
-- next, not to this stub.
--
-- Bank account numbers are encrypted at rest (pgp_sym_encrypt) rather than
-- hashed like handover codes (0028), because a real payout will eventually
-- need the plaintext back to actually wire money -- a hash cannot do that.
-- No decrypt path is built here: this phase never needs to read the number
-- back, only account_no_last4 (plaintext, for display/confirmation). Decrypt
-- is deliberately deferred to whatever migration wires up a real provider.
--
-- The encryption key is read from the Postgres GUC app.settings.
-- bank_account_enc_key, which THIS MIGRATION DOES NOT SET -- a secret has no
-- business living in a file this project commits to git. Before this
-- feature can be used on a real project, set it once via the Supabase
-- dashboard (Project Settings -> Database -> Custom Postgres Config) or
-- `ALTER DATABASE postgres SET app.settings.bank_account_enc_key = '<random
-- 32+ byte secret>';`. Until then rpc_add_bank_account fails closed with
-- BANK_ACCOUNT_ENC_KEY_NOT_CONFIGURED rather than silently encrypting with
-- a guessable default. CI/local tests set the GUC for the session
-- themselves (supabase/test_helpers/00_helpers.sql) since no dashboard
-- exists there.
-- ============================================================================

CREATE INDEX IF NOT EXISTS ix_bank_accounts_owner ON internal.bank_accounts(owner_id);
CREATE INDEX IF NOT EXISTS ix_payouts_payee ON internal.payouts(payee_type, payee_id);

-- ── Encryption key lookup ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION internal.fn_bank_account_enc_key()
RETURNS TEXT LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE v_key TEXT;
BEGIN
  v_key := current_setting('app.settings.bank_account_enc_key', true);
  IF v_key IS NULL OR length(v_key) < 16 THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_ENC_KEY_NOT_CONFIGURED';
  END IF;
  RETURN v_key;
END $$;

-- ── 1. Add a bank account ────────────────────────────────────────────────────
-- Any authenticated carrier or seller may register one; there is no cap and
-- no verification step here (internal.bank_accounts.verified_at exists for a
-- future KYC pass, not this one). owner_id is the human (auth.uid()), not
-- the carrier/seller row, because the same person could hold both roles and
-- reasonably reuse one bank account across them.
--
-- search_path is pinned to an explicit allowlist rather than '' here, unlike
-- every other function in this file: pgp_sym_encrypt lives in the pgcrypto
-- extension, which 0000_prelude.sql installs without a target schema --
-- this project's own production database puts it in `public` (confirmed by
-- querying pg_extension directly; the ambiguity 0028's fn_handover_digest
-- comment raises about `extensions` is why that function stuck to
-- pg_catalog builtins instead -- a digest-only comparison had that luxury;
-- encrypting a real bank account number for later use does not). Every
-- schema on this list (pg_catalog, public, extensions) is owned by this
-- project or by Supabase itself, never by a client role, so this is not the
-- search-path-hijack risk that an empty search_path guards against.
--
-- `SET search_path = '...'` (a single quoted string) is NOT the same as
-- `SET search_path TO a, b, c`: the quoted-string form was verified live to
-- store the literal string "a, b, c" as ONE schema name, matching nothing
-- and silently making pgp_sym_encrypt unresolvable -- TO with unquoted,
-- comma-separated names is the only form that actually expands to multiple
-- schemas in a function's own SET clause.
CREATE OR REPLACE FUNCTION public.rpc_add_bank_account(
  p_bank_code TEXT, p_account_no TEXT, p_holder_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO pg_catalog, public, extensions
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_last4 TEXT;
  v_id UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF authz.my_carrier_id() IS NULL AND authz.my_seller_id() IS NULL THEN
    RAISE EXCEPTION 'NOT_A_PAYEE';
  END IF;

  IF trim(coalesce(p_bank_code,'')) = '' THEN RAISE EXCEPTION 'INVALID_BANK_CODE'; END IF;
  IF trim(coalesce(p_holder_name,'')) = '' THEN RAISE EXCEPTION 'INVALID_HOLDER_NAME'; END IF;

  v_last4 := right(regexp_replace(coalesce(p_account_no,''), '\D', '', 'g'), 4);
  IF length(v_last4) < 4 THEN RAISE EXCEPTION 'INVALID_ACCOUNT_NO'; END IF;

  INSERT INTO internal.bank_accounts
    (owner_id, bank_code, account_no_enc, account_no_last4, holder_name)
  VALUES (
    v_uid, upper(trim(p_bank_code)),
    pgp_sym_encrypt(p_account_no, internal.fn_bank_account_enc_key()),
    v_last4, trim(p_holder_name))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'id', v_id, 'bank_code', upper(trim(p_bank_code)),
    'account_no_last4', v_last4, 'holder_name', trim(p_holder_name));
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_my_bank_accounts()
RETURNS TABLE (
  id UUID, bank_code TEXT, account_no_last4 TEXT, holder_name TEXT,
  verified_at TIMESTAMPTZ, created_at TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT id, bank_code, account_no_last4, holder_name, verified_at, created_at
    FROM internal.bank_accounts
   WHERE owner_id = auth.uid()
   ORDER BY created_at DESC;
$$;

-- ── 2. Request a withdrawal ──────────────────────────────────────────────────
-- v_pending subtracts every payout this payee already has in flight
-- (REQUESTED through PROCESSING): the ledger balance is never decremented
-- until rpc_admin_mark_payout_paid actually posts (fn_account_balance_sen's
-- own comment says payouts are deliberately not netted into it), so without
-- this a payee could request the same balance twice before either was paid.
CREATE OR REPLACE FUNCTION public.rpc_request_withdrawal(
  p_payee_type TEXT, p_bank_account_id UUID, p_amount_sen BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  v_payee_id UUID;
  v_available BIGINT;
  v_pending BIGINT;
  v_id UUID;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_payee_type NOT IN ('carrier','seller') THEN RAISE EXCEPTION 'INVALID_PAYEE_TYPE'; END IF;
  IF p_amount_sen <= 0 THEN RAISE EXCEPTION 'INVALID_AMOUNT'; END IF;

  v_payee_id := CASE WHEN p_payee_type = 'carrier'
                      THEN authz.my_carrier_id() ELSE authz.my_seller_id() END;
  IF v_payee_id IS NULL THEN
    RAISE EXCEPTION '%', CASE WHEN p_payee_type = 'carrier' THEN 'NOT_A_CARRIER' ELSE 'NOT_A_SELLER' END;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM internal.bank_accounts
                  WHERE id = p_bank_account_id AND owner_id = v_uid) THEN
    RAISE EXCEPTION 'BANK_ACCOUNT_NOT_FOUND';
  END IF;

  v_available := internal.fn_account_balance_sen(upper(p_payee_type)||'_PAYABLE:'||v_payee_id::text);
  SELECT COALESCE(SUM(amount_sen), 0) INTO v_pending
    FROM internal.payouts
   WHERE payee_type = p_payee_type AND payee_id = v_payee_id
     AND status IN ('REQUESTED','UNDER_REVIEW','APPROVED','BATCHED','PROCESSING');

  IF p_amount_sen > (v_available - v_pending) THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE'; END IF;

  INSERT INTO internal.payouts (payee_type, payee_id, amount_sen, bank_account_id)
  VALUES (p_payee_type, v_payee_id, p_amount_sen, p_bank_account_id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('id', v_id, 'status', 'REQUESTED', 'amount_sen', p_amount_sen);
END;
$function$;

CREATE OR REPLACE FUNCTION public.rpc_my_payouts()
RETURNS TABLE (
  id UUID, payee_type TEXT, amount_sen BIGINT, status TEXT,
  bank_code TEXT, account_no_last4 TEXT,
  requested_at TIMESTAMPTZ, paid_at TIMESTAMPTZ, failure_reason TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p.id, p.payee_type, p.amount_sen, p.status::text,
         b.bank_code, b.account_no_last4, p.requested_at, p.paid_at, p.failure_reason
    FROM internal.payouts p
    JOIN internal.bank_accounts b ON b.id = p.bank_account_id
   WHERE (p.payee_type = 'carrier' AND p.payee_id = authz.my_carrier_id())
      OR (p.payee_type = 'seller' AND p.payee_id = authz.my_seller_id())
   ORDER BY p.requested_at DESC;
$$;

-- ── 3. Admin queue and maker-checker actions ─────────────────────────────────
-- Every non-final payout, across every payee -- mirrors the other admin
-- queues (listSellerApplications etc.) in returning the actionable set
-- rather than full history, since internal.payouts has no RLS an admin
-- could otherwise read through (schema internal has no client grant at all).
CREATE OR REPLACE FUNCTION public.rpc_admin_list_payouts()
RETURNS TABLE (
  id UUID, payee_type TEXT, payee_label TEXT, amount_sen BIGINT, status TEXT,
  bank_code TEXT, account_no_last4 TEXT, holder_name TEXT,
  reviewed_by UUID, approved_by UUID, requested_at TIMESTAMPTZ)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $function$
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  RETURN QUERY
  SELECT p.id, p.payee_type,
         CASE WHEN p.payee_type = 'carrier'
                THEN (SELECT pr.full_name FROM public.carriers c
                       JOIN public.profiles pr ON pr.id = c.user_id WHERE c.id = p.payee_id)
              ELSE (SELECT s.business_name FROM public.sellers s WHERE s.id = p.payee_id)
         END,
         p.amount_sen, p.status::text,
         b.bank_code, b.account_no_last4, b.holder_name,
         p.reviewed_by, p.approved_by, p.requested_at
    FROM internal.payouts p
    JOIN internal.bank_accounts b ON b.id = p.bank_account_id
   WHERE p.status IN ('REQUESTED','UNDER_REVIEW','APPROVED','BATCHED','PROCESSING')
   ORDER BY p.requested_at ASC;
END;
$function$;

/** First look: REQUESTED -> UNDER_REVIEW, or straight to REJECTED. Rejecting
 *  needs no second admin -- only paying money out does. */
CREATE OR REPLACE FUNCTION public.rpc_admin_review_payout(
  p_payout_id UUID, p_approve BOOLEAN, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_payout internal.payouts;
  v_status ref.payout_status := CASE WHEN p_approve THEN 'UNDER_REVIEW' ELSE 'REJECTED' END::ref.payout_status;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  UPDATE internal.payouts SET
    status      = v_status,
    reviewed_by = (SELECT auth.uid()),
    failure_reason = CASE WHEN p_approve THEN failure_reason ELSE p_reason END
  WHERE id = p_payout_id AND status = 'REQUESTED'
  RETURNING * INTO v_payout;

  IF v_payout.id IS NULL THEN RAISE EXCEPTION 'INVALID_PAYOUT_STATE'; END IF;
  RETURN jsonb_build_object('id', v_payout.id, 'status', v_payout.status);
END;
$function$;

/** Second look, by someone else: UNDER_REVIEW -> APPROVED, or REJECTED.
 *  ck_payout_segregation (0001) backs this at the constraint level too --
 *  the check here exists to fail with a clear error before that raw
 *  constraint violation would. */
CREATE OR REPLACE FUNCTION public.rpc_admin_approve_payout(
  p_payout_id UUID, p_approve BOOLEAN, p_reason TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_payout internal.payouts;
  v_uid UUID := (SELECT auth.uid());
  v_status ref.payout_status := CASE WHEN p_approve THEN 'APPROVED' ELSE 'REJECTED' END::ref.payout_status;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  IF EXISTS (SELECT 1 FROM internal.payouts
              WHERE id = p_payout_id AND status = 'UNDER_REVIEW' AND reviewed_by = v_uid) THEN
    RAISE EXCEPTION 'CANNOT_APPROVE_OWN_REVIEW';
  END IF;

  UPDATE internal.payouts SET
    status      = v_status,
    approved_by = CASE WHEN p_approve THEN v_uid ELSE approved_by END,
    failure_reason = CASE WHEN p_approve THEN failure_reason ELSE p_reason END
  WHERE id = p_payout_id AND status = 'UNDER_REVIEW'
  RETURNING * INTO v_payout;

  IF v_payout.id IS NULL THEN RAISE EXCEPTION 'INVALID_PAYOUT_STATE'; END IF;
  RETURN jsonb_build_object('id', v_payout.id, 'status', v_payout.status);
END;
$function$;

/** The only step that moves money -- everywhere else in this file is
 *  record-keeping. Re-checks the live balance rather than trusting the one
 *  rpc_request_withdrawal saw: time has passed, and another payout for the
 *  same payee may have been marked PAID in between. provider_ref is
 *  whatever reference the admin's manual/offline transfer produced -- this
 *  function never calls a real disbursement rail (see this file's header). */
CREATE OR REPLACE FUNCTION public.rpc_admin_mark_payout_paid(
  p_payout_id UUID, p_provider_ref TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE
  v_payout internal.payouts;
  v_available BIGINT;
  v_txn UUID;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  SELECT * INTO v_payout FROM internal.payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN RAISE EXCEPTION 'PAYOUT_NOT_FOUND'; END IF;
  IF v_payout.status <> 'APPROVED' THEN RAISE EXCEPTION 'INVALID_PAYOUT_STATE'; END IF;

  v_available := internal.fn_account_balance_sen(
    upper(v_payout.payee_type)||'_PAYABLE:'||v_payout.payee_id::text);
  IF v_available < v_payout.amount_sen THEN RAISE EXCEPTION 'INSUFFICIENT_BALANCE_AT_SETTLEMENT'; END IF;

  INSERT INTO internal.ledger_transactions
    (kind, reference_type, reference_id, idempotency_key, description, created_by)
  VALUES ('PAYOUT', 'payout', p_payout_id, 'payout:'||p_payout_id::text,
          'Payout '||v_payout.payee_type||' '||v_payout.payee_id::text, (SELECT auth.uid()))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING id INTO v_txn;
  IF v_txn IS NULL THEN RAISE EXCEPTION 'ALREADY_PAID'; END IF;

  PERFORM internal.fn_post(v_txn,
    upper(v_payout.payee_type)||'_PAYABLE:'||v_payout.payee_id::text, 'DEBIT', v_payout.amount_sen);
  PERFORM internal.fn_post(v_txn, 'BANK_OPERATING', 'CREDIT', v_payout.amount_sen);

  UPDATE internal.payouts SET status = 'PAID', provider_ref = p_provider_ref, paid_at = now()
   WHERE id = p_payout_id;

  RETURN jsonb_build_object('id', p_payout_id, 'status', 'PAID');
END;
$function$;

/** APPROVED -> FAILED with no ledger effect: this stub's only money movement
 *  happens in rpc_admin_mark_payout_paid, so a failure recorded before that
 *  step never touched the ledger in the first place. */
CREATE OR REPLACE FUNCTION public.rpc_admin_mark_payout_failed(
  p_payout_id UUID, p_reason TEXT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $function$
DECLARE v_payout internal.payouts;
BEGIN
  IF NOT authz.is_admin() THEN RAISE EXCEPTION 'STATE_ACTOR_NOT_PERMITTED'; END IF;

  UPDATE internal.payouts SET status = 'FAILED', failure_reason = p_reason
  WHERE id = p_payout_id AND status = 'APPROVED'
  RETURNING * INTO v_payout;

  IF v_payout.id IS NULL THEN RAISE EXCEPTION 'INVALID_PAYOUT_STATE'; END IF;
  RETURN jsonb_build_object('id', v_payout.id, 'status', v_payout.status);
END;
$function$;

-- ── 4. Grants ────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION internal.fn_bank_account_enc_key() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.rpc_add_bank_account(TEXT,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_add_bank_account(TEXT,TEXT,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_my_bank_accounts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_bank_accounts() TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_request_withdrawal(TEXT,UUID,BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_request_withdrawal(TEXT,UUID,BIGINT) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_my_payouts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_my_payouts() TO authenticated;

REVOKE ALL ON FUNCTION public.rpc_admin_list_payouts() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_list_payouts() TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_review_payout(UUID,BOOLEAN,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_review_payout(UUID,BOOLEAN,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_approve_payout(UUID,BOOLEAN,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_approve_payout(UUID,BOOLEAN,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_mark_payout_paid(UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_mark_payout_paid(UUID,TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.rpc_admin_mark_payout_failed(UUID,TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_mark_payout_failed(UUID,TEXT) TO authenticated;
