-- ============================================================================
-- KasihKirim — 0022_deck_badge_awards.sql
--
-- 0020_jualan_checkout_and_growth.sql seeded three badges of its own
-- invention (verified_seller/verified_carrier/trusted_carrier) before
-- discovering, while wiring the Android side, that supabase/seed.sql
-- already ships the real, deck-confirmed catalog ("profile shows Lencana,
-- starting with Kirim Pertama"): kirim-pertama, kirim-sepuluh, dipercayai,
-- sokong-kampung, pembawa-setia -- each with a `rule` JSONB already stating
-- its own threshold. Building award logic around three names the deck never
-- specified would be exactly the kind of invented content this project has
-- consistently avoided (route distances, geography). This migration retracts
-- that guess and wires the five real ones instead.
--
-- No production user could have earned the retracted badges: 0020 shipped
-- and this correction follows in the same batch, before any Android build
-- reading them existed.
-- ============================================================================
DROP TRIGGER IF EXISTS tg_sellers_award_badge ON public.sellers;
DROP TRIGGER IF EXISTS tg_carriers_award_badges ON public.carriers;
DROP FUNCTION IF EXISTS internal.tg_award_seller_verified_badge();
DROP FUNCTION IF EXISTS internal.tg_award_carrier_badges();

DELETE FROM public.user_badges WHERE badge_id IN (
  SELECT id FROM ref.badge_definitions
   WHERE slug IN ('verified_seller','verified_carrier','trusted_carrier')
);
DELETE FROM ref.badge_definitions
 WHERE slug IN ('verified_seller','verified_carrier','trusted_carrier');

-- ── kirim-pertama {"kirim_completed":1} / kirim-sepuluh {"kirim_completed":10}
--    / sokong-kampung {"communities":2} ────────────────────────────────────
-- fn_settle_delivery (0003) is the only place a kirim_requests row is ever
-- set to COMPLETED (on the recipient's CONFIRM_RECEIPT), so that is the one
-- real completion event to hook.
CREATE OR REPLACE FUNCTION internal.tg_award_kirim_badges()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_completed INT; v_communities INT;
BEGIN
  IF NEW.status = 'COMPLETED' AND (OLD.status IS DISTINCT FROM 'COMPLETED') THEN
    SELECT count(*) INTO v_completed FROM public.kirim_requests
     WHERE requester_id = NEW.requester_id AND status = 'COMPLETED';
    IF v_completed >= 1  THEN PERFORM internal.fn_award_badge(NEW.requester_id, 'kirim-pertama'); END IF;
    IF v_completed >= 10 THEN PERFORM internal.fn_award_badge(NEW.requester_id, 'kirim-sepuluh'); END IF;

    SELECT count(DISTINCT a.community_id) INTO v_communities
      FROM public.kirim_requests k JOIN public.addresses a ON a.id = k.dest_address_id
     WHERE k.requester_id = NEW.requester_id AND k.status = 'COMPLETED';
    IF v_communities >= 2 THEN PERFORM internal.fn_award_badge(NEW.requester_id, 'sokong-kampung'); END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_kirim_award_badges AFTER UPDATE OF status ON public.kirim_requests
  FOR EACH ROW EXECUTE FUNCTION internal.tg_award_kirim_badges();

-- ── pembawa-setia {"deliveries_completed":25} ───────────────────────────────
-- carriers.completed_count is already incremented by fn_settle_delivery
-- (0003) at the same COMPLETED transition above.
CREATE OR REPLACE FUNCTION internal.tg_award_carrier_loyalty_badge()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.completed_count >= 25 AND OLD.completed_count < 25 THEN
    PERFORM internal.fn_award_badge(NEW.user_id, 'pembawa-setia');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_carriers_award_loyalty_badge AFTER UPDATE OF completed_count ON public.carriers
  FOR EACH ROW EXECUTE FUNCTION internal.tg_award_carrier_loyalty_badge();

-- ── dipercayai {"rating_avg":4.5,"rating_count":10} ─────────────────────────
-- Wired now so it fires the moment something populates
-- profiles.rating_avg/rating_count -- nothing does yet. reviews_insert
-- (0003) lets a completed delivery's participant post a review, but no
-- migration aggregates reviews back into the profile the protective
-- tg_protect_profile_columns trigger (0003) otherwise locks those two
-- columns against. That aggregation is the separate Reviews & ratings
-- subsystem (not part of this batch); this trigger is inert until it
-- exists, and correct the moment it does.
CREATE OR REPLACE FUNCTION internal.tg_award_rating_badge()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.rating_avg >= 4.5 AND NEW.rating_count >= 10
     AND (OLD.rating_avg < 4.5 OR OLD.rating_count < 10) THEN
    PERFORM internal.fn_award_badge(NEW.id, 'dipercayai');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_profiles_award_rating_badge AFTER UPDATE OF rating_avg, rating_count ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION internal.tg_award_rating_badge();
