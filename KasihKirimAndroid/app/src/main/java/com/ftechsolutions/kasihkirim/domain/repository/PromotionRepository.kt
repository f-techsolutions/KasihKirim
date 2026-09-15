package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CreatedPromotion
import com.ftechsolutions.kasihkirim.domain.model.MyPromotions
import com.ftechsolutions.kasihkirim.domain.model.OpenedPromotion
import com.ftechsolutions.kasihkirim.domain.model.PromotionSubjectType

/** Kongsi & Untung (0045_kongsi_untung_promotions.sql) -- every RPC here
 *  refuses with KONGSI_UNTUNG_DISABLED while ref.feature_gates.
 *  kongsi_untung_enabled is off, which it is in production pending legal
 *  review (docs/MUATAN-JUAL-COMPLIANCE.md). Payout/withdrawal for a
 *  promoter's own earnings goes through the existing EarningsRepository
 *  (PayeeType.PROMOTER) -- rpc_request_withdrawal/rpc_my_payouts/
 *  rpc_add_bank_account/rpc_my_bank_accounts are payee-type-generic
 *  already and needed no new repository methods of their own. */
interface PromotionRepository {
    /** rpc_create_promotion. Idempotent per (caller, subject) server-side --
     *  calling this again for the same subject returns the same code. */
    suspend fun createPromotion(subjectType: PromotionSubjectType, subjectId: String): AppResult<CreatedPromotion>

    /** rpc_open_promotion. Callable signed out (anon) too. */
    suspend fun openPromotion(code: String): AppResult<OpenedPromotion>

    /** rpc_my_promotions. Not gated -- a promoter can still see money
     *  already earned even if the feature is later switched off. */
    suspend fun myPromotions(): AppResult<MyPromotions>
}
