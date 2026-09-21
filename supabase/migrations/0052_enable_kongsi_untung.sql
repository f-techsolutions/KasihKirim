-- Kongsi & Untung (promoter referral programme) go-live, per explicit owner
-- instruction (2026-09-20/21). This is a pure business decision, distinct
-- from Muatan Jual / prepaid Kirim:
--
--   * kongsi_untung_enabled is checked directly by its own RPCs
--     (0045_kongsi_untung_promotions.sql). It is NOT in the
--     internal.fn_marketplace_gate() call path and does not require
--     ref.compliance_state to leave NOT_READY.
--   * Promoter earnings are a share of platform commission, never a share
--     of escrowed customer funds -- so this does not touch MJ-01 (the
--     BNM e-money licensing question at docs/MUATAN-JUAL-COMPLIANCE.md §8
--     that blocks Muatan Jual checkout and prepaid payments).
--
-- Still outstanding and NOT resolved by this migration:
--   docs/MUATAN-JUAL-COMPLIANCE.md §2.4 flags promoter-disclosure
--   obligations and promoter income-tax registration as
--   LEGAL REVIEW REQUIRED. Flip is made on the owner's explicit
--   instruction; tracking that question remains the owner's own action
--   item, separate from engineering scope.
UPDATE ref.feature_gates
SET enabled = true,
    changed_at = now(),
    change_reason = 'Enabled per explicit owner instruction. Independent of ref.compliance_state; commission-share only, no escrowed customer funds. §2.4 promoter-disclosure/tax LEGAL REVIEW REQUIRED item remains open and untouched by this change.'
WHERE key = 'kongsi_untung_enabled';
