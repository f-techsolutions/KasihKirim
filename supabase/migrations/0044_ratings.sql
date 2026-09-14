-- ============================================================================
-- KasihKirim — 0044_ratings.sql
--
-- Phase 2 (Trust & retention): ratings. public.reviews (0001), its RLS (0003)
-- and the badge trigger that watches for it (0022's own tg_award_rating_badge)
-- have existed since early in the project -- 0022's comment says outright
-- that "profiles.rating_avg/rating_count -- nothing does yet. ... That
-- aggregation is the separate Reviews & ratings subsystem." This migration
-- is that subsystem.
--
-- Two things this closes:
--
--   1. reviews_insert (0003) lets ANY authenticated user insert a review for
--      ANY COMPLETED delivery, naming themselves rater_id and anyone at all
--      as ratee_id -- there is no check that the rater was actually a party
--      to that delivery. rpc_submit_review below is the fix: it derives
--      ratee_id itself from the delivery's own requester/carrier and refuses
--      anyone else with NOT_A_PARTY. The direct INSERT grant is revoked so
--      this RPC is the only write path -- same reasoning as every other
--      RPC-gated table in this codebase (payouts, dispute resolution, ...).
--
--   2. Nothing ever aggregated reviews into profiles.rating_avg/rating_count
--      (or carriers.rating_avg), and nothing ever flipped reviews.is_visible
--      away from its default false -- so no rating has ever been visible to
--      anyone but its own rater. This migration adds the double-blind reveal
--      (both sides' reviews become visible together, the moment both exist,
--      so neither can shape their own review after reading the other's) and
--      a sweep for the one-sided case (the other party never rated) that
--      reveals a solo review once its own edit window has closed -- by then
--      the editable_until (0001) has still cut off *this* review too, so
--      revealing doesn't unlock a way to see a comeback rating land the same
--      side up.
-- ============================================================================

-- ── 1. A scoped bypass for the profile-column protection trigger ───────────
-- internal.tg_protect_profile_columns (0003) forces rating_avg/rating_count
-- back to OLD for anyone who isn't authz.is_admin() -- which is everyone in
-- a normal authenticated request, SECURITY DEFINER or not: SECURITY DEFINER
-- elevates table privilege, not the JWT claims authz.is_admin() reads, so a
-- plain UPDATE from inside rpc_submit_review would silently no-op exactly
-- the two columns it exists to write. SET LOCAL on a custom GUC is already
-- this codebase's way to hand a trusted transaction a capability an ordinary
-- session doesn't have (0042's bank_account_enc_key) -- same mechanism here,
-- scoped to one flag that only internal.fn_recompute_rating ever sets.
CREATE OR REPLACE FUNCTION internal.tg_protect_profile_columns()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF authz.is_admin() OR current_setting('app.internal.rating_write', true) = 'true' THEN
    RETURN NEW;
  END IF;
  NEW.status := OLD.status;
  NEW.rating_avg := OLD.rating_avg;
  NEW.rating_count := OLD.rating_count;
  NEW.kirim_sent_count := OLD.kirim_sent_count;
  NEW.kirim_received_count := OLD.kirim_received_count;
  NEW.phone := OLD.phone;
  NEW.nric_hash := OLD.nric_hash;
  RETURN NEW;
END $$;

-- ── 2. Aggregation ───────────────────────────────────────────────────────────
/** Recomputes p_user_id's public rating from their VISIBLE reviews only --
 *  an invisible (not yet double-blind-revealed) review has no public effect
 *  yet, by design. Also updates carriers.rating_avg when p_user_id is a
 *  carrier (that table carries no RLS-write protection of its own -- a
 *  SECURITY DEFINER function's owner already bypasses RLS on it, same as
 *  every other internal.fn_* in this codebase writing tables it doesn't
 *  expose to clients directly). */
CREATE OR REPLACE FUNCTION internal.fn_recompute_rating(p_user_id UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_avg NUMERIC(3,2); v_count INT;
BEGIN
  SELECT COALESCE(ROUND(AVG(rating), 2), 0), COUNT(*)
    INTO v_avg, v_count
    FROM public.reviews
   WHERE ratee_id = p_user_id AND is_visible = true;

  PERFORM set_config('app.internal.rating_write', 'true', true);

  UPDATE public.profiles
     SET rating_avg = v_avg, rating_count = v_count, updated_at = now()
   WHERE id = p_user_id;

  UPDATE public.carriers
     SET rating_avg = v_avg, updated_at = now()
   WHERE user_id = p_user_id;
END $$;

-- ── 3. Submitting a review ──────────────────────────────────────────────────
/** The only write path onto public.reviews (INSERT is revoked from
 *  authenticated below). Validates the caller was actually a party to the
 *  delivery, derives ratee_id from the delivery itself rather than trusting
 *  a client-supplied one, and reveals both sides' reviews the instant both
 *  exist. Editable within reviews.editable_until (24h, 0001's own default)
 *  same as a fresh submission -- past that, EDIT_WINDOW_CLOSED. */
CREATE OR REPLACE FUNCTION public.rpc_submit_review(
  p_delivery_id UUID, p_rating INT, p_comment TEXT DEFAULT NULL)
RETURNS public.reviews
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE
  v_uid UUID := auth.uid();
  d public.deliveries;
  v_carrier_user UUID;
  v_ratee UUID;
  v_existing public.reviews;
  v_review public.reviews;
  v_review_count INT;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_rating NOT BETWEEN 1 AND 5 THEN RAISE EXCEPTION 'INVALID_RATING'; END IF;

  SELECT * INTO d FROM public.deliveries WHERE id = p_delivery_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DELIVERY_NOT_FOUND'; END IF;
  IF d.status <> 'COMPLETED' THEN RAISE EXCEPTION 'DELIVERY_NOT_COMPLETED'; END IF;

  SELECT c.user_id INTO v_carrier_user FROM public.carriers c WHERE c.id = d.carrier_id;

  IF v_uid = d.requester_id THEN
    v_ratee := v_carrier_user;
  ELSIF v_uid = v_carrier_user THEN
    v_ratee := d.requester_id;
  ELSE
    RAISE EXCEPTION 'NOT_A_PARTY';
  END IF;

  SELECT * INTO v_existing FROM public.reviews
   WHERE delivery_id = p_delivery_id AND rater_id = v_uid;

  IF v_existing.id IS NOT NULL THEN
    IF v_existing.editable_until <= now() THEN
      RAISE EXCEPTION 'EDIT_WINDOW_CLOSED';
    END IF;
    UPDATE public.reviews
       SET rating = p_rating, comment = p_comment
     WHERE id = v_existing.id
    RETURNING * INTO v_review;
  ELSE
    INSERT INTO public.reviews (delivery_id, rater_id, ratee_id, rating, comment)
    VALUES (p_delivery_id, v_uid, v_ratee, p_rating, p_comment)
    RETURNING * INTO v_review;
  END IF;

  SELECT count(*) INTO v_review_count
    FROM public.reviews WHERE delivery_id = p_delivery_id;

  IF v_review_count = 2 AND EXISTS (
    SELECT 1 FROM public.reviews WHERE delivery_id = p_delivery_id AND NOT is_visible
  ) THEN
    -- Both sides have now rated: reveal together, then recompute both
    -- ratees' public ratings from their now-visible reviews.
    UPDATE public.reviews SET is_visible = true WHERE delivery_id = p_delivery_id;
    PERFORM internal.fn_recompute_rating(r.ratee_id)
      FROM public.reviews r WHERE r.delivery_id = p_delivery_id;
  ELSIF v_review.is_visible THEN
    -- Editing an already-revealed review only ever changes this rater's own
    -- ratee's aggregate -- the other side's review and visibility are unmoved.
    PERFORM internal.fn_recompute_rating(v_review.ratee_id);
  END IF;

  SELECT * INTO v_review FROM public.reviews
   WHERE delivery_id = p_delivery_id AND rater_id = v_uid;
  RETURN v_review;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_submit_review(UUID, INT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_submit_review(UUID, INT, TEXT) TO authenticated;

-- Superseded by rpc_submit_review, which derives ratee_id itself and checks
-- delivery membership -- reviews_insert (0003) checked neither. Revoking the
-- grant (not just dropping the policy) is what actually closes the gap:
-- GRANT is checked before RLS, so this makes a direct client INSERT fail
-- before reviews_insert's WITH CHECK is even evaluated.
REVOKE INSERT ON public.reviews FROM authenticated;
DROP POLICY IF EXISTS reviews_insert ON public.reviews;

-- ── 4. Sweep: reveal a one-sided review once its own window has closed ─────
-- The counterpart never rated -- or rated after this one's window closed,
-- which the UNIQUE(delivery_id, rater_id) + this same sweep still resolves
-- the next time it runs. Mirrors internal.fn_sweep_settlements (0029): one
-- job_runs row per run, each reveal independent so one failure can't sink
-- the batch, safe to run repeatedly and concurrently (a second sweep over an
-- already-visible row is a no-op, not a double reveal).
CREATE OR REPLACE FUNCTION internal.fn_sweep_reveal_reviews(p_limit INT DEFAULT 500)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r RECORD; v_run UUID;
  v_examined INT := 0; v_revealed INT := 0;
BEGIN
  INSERT INTO internal.job_runs (job_name) VALUES ('reveal_expired_reviews')
  RETURNING id INTO v_run;

  FOR r IN
    SELECT id, ratee_id FROM public.reviews
     WHERE NOT is_visible AND editable_until < now()
     ORDER BY editable_until
     LIMIT GREATEST(1, p_limit)
  LOOP
    v_examined := v_examined + 1;
    BEGIN
      UPDATE public.reviews SET is_visible = true WHERE id = r.id;
      PERFORM internal.fn_recompute_rating(r.ratee_id);
      v_revealed := v_revealed + 1;
    EXCEPTION WHEN OTHERS THEN
      -- Contained, same as fn_sweep_settlements: one bad row never sinks the batch.
      NULL;
    END;
  END LOOP;

  UPDATE internal.job_runs
     SET ended_at = now(), outcome = 'OK',
         detail = jsonb_build_object('examined', v_examined, 'revealed', v_revealed)
   WHERE id = v_run;

  RETURN jsonb_build_object('examined', v_examined, 'revealed', v_revealed);
END $$;

REVOKE ALL ON FUNCTION internal.fn_sweep_reveal_reviews(INT) FROM PUBLIC, anon, authenticated;

-- First-time schedule (no prior job to unschedule); pg_cron is absent in CI
-- and in the local harness, same guard as 0029's own scheduling block.
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('reveal_expired_reviews', '*/15 * * * *',
      $j$SELECT internal.fn_sweep_reveal_reviews()$j$);
  END IF;
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pg_cron unavailable (%). reveal_expired_reviews left unscheduled.', SQLERRM;
END $cron$;
