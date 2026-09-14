package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AccountStatus
import com.ftechsolutions.kasihkirim.domain.model.AdminAccount
import com.ftechsolutions.kasihkirim.domain.model.AdminOrderSearchResult
import com.ftechsolutions.kasihkirim.domain.model.AdminPayout
import com.ftechsolutions.kasihkirim.domain.model.AdminPaymentRecord
import com.ftechsolutions.kasihkirim.domain.model.CarrierApplication
import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
import com.ftechsolutions.kasihkirim.domain.model.ProductReview
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.SellerApplication
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus

/**
 * The admin review queues (0023_admin_review_surface.sql).
 *
 * Reads go straight to the tables: sellers_select, products_select and
 * disputes_select each already carry an `OR authz.is_admin()` clause (0003),
 * so an admin's own RLS lets them see every row and a non-admin sees nothing
 * extra -- there is no queue-reader RPC to keep in step with those policies.
 *
 * Writes go through RPCs, because each one has to do more than set a column:
 * approving a seller also grants the role its JWT claim is built from, and
 * resolving a dispute also clears the escrow hold that blocks settlement.
 */
interface AdminRepository {
    /** Applications not yet APPROVED/REJECTED, oldest first -- a queue. */
    suspend fun listSellerApplications(): AppResult<List<SellerApplication>>

    /** rpc_admin_set_seller_status. On APPROVED this also grants the seller
     *  role, which only reaches the applicant's session at their next sign-in. */
    suspend fun setSellerStatus(sellerId: String, status: SellerStatus, reason: String?): AppResult<Unit>

    /** Applications not yet APPROVED/REJECTED, oldest first -- a queue. */
    suspend fun listCarrierApplications(): AppResult<List<CarrierApplication>>

    /** rpc_admin_set_carrier_status (0040). On APPROVED this also grants the
     *  carrier role, which only reaches the applicant's session at their next
     *  sign-in -- same as setSellerStatus's own APPROVED case. */
    suspend fun setCarrierStatus(carrierId: String, status: SellerStatus, reason: String?): AppResult<Unit>

    /** Products in draft or pending_review, oldest first. */
    suspend fun listProductReviews(): AppResult<List<ProductReview>>

    /** rpc_admin_set_product_status (0018). */
    suspend fun setProductStatus(productId: String, status: ProductStatus, rejectionReason: String?): AppResult<Unit>

    /** Disputes that are not yet in a final state. */
    suspend fun listOpenDisputes(): AppResult<List<Dispute>>

    /** rpc_admin_resolve_dispute. A final status stamps resolved_at and clears
     *  holds_escrow; refund_sen is recorded, never posted to the ledger. */
    suspend fun resolveDispute(
        disputeId: String,
        status: DisputeStatus,
        note: String?,
        refundSen: Long,
    ): AppResult<Unit>

    /** Not a queue: profiles matching [query] against phone or full name,
     *  merged from two separate ilike reads (postgrest-kt's `or {}` filter
     *  combinator has no proven working example anywhere in this module,
     *  same caution the other queue reads here already document). Empty
     *  query returns no results rather than the whole user base. */
    suspend fun searchAccounts(query: String): AppResult<List<AdminAccount>>

    /** rpc_admin_set_account_status (0041). Unlike every other rpc_admin_*
     *  write in this file, this one is actually enforced server-side --
     *  custom_access_token_hook now refuses to mint a token at all for a
     *  SUSPENDED/BANNED account, not just label it that way. */
    suspend fun setAccountStatus(userId: String, status: AccountStatus, reason: String?): AppResult<Unit>

    /** rpc_admin_list_payouts (0042). The actionable set only (REQUESTED
     *  through PROCESSING), same reasoning as the other queues here --
     *  internal.payouts has no RLS an admin could otherwise read through. */
    suspend fun listPayouts(): AppResult<List<AdminPayout>>

    /** rpc_admin_review_payout: first look. REQUESTED -> UNDER_REVIEW or
     *  REJECTED. Needs no second admin -- only paying money out does. */
    suspend fun reviewPayout(payoutId: String, approve: Boolean, reason: String?): AppResult<Unit>

    /** rpc_admin_approve_payout: second look, by someone else. UNDER_REVIEW
     *  -> APPROVED or REJECTED. The server refuses the same admin who
     *  reviewed it (CANNOT_APPROVE_OWN_REVIEW) -- this is the actual
     *  maker-checker enforcement, backed by ck_payout_segregation (0001). */
    suspend fun approvePayout(payoutId: String, approve: Boolean, reason: String?): AppResult<Unit>

    /** rpc_admin_mark_payout_paid: the only step that posts to the ledger.
     *  providerRef is whatever reference a manual/offline transfer produced
     *  -- this never calls a real disbursement rail (0042's own header). */
    suspend fun markPayoutPaid(payoutId: String, providerRef: String?): AppResult<Unit>

    /** rpc_admin_mark_payout_failed. No ledger effect: money never moved. */
    suspend fun markPayoutFailed(payoutId: String, reason: String): AppResult<Unit>

    /** rpc_admin_search_order (0043). Not a queue -- one search box, one
     *  result: reference codes are UNIQUE on both kirim_requests and orders.
     *  Returns null on no match or a blank query rather than an empty list,
     *  so the UI can tell "nothing typed yet" from "typed, found nothing". */
    suspend fun searchOrder(query: String): AppResult<AdminOrderSearchResult?>

    /** rpc_admin_recent_payments (0043). The platform's most recent payment
     *  activity, newest first -- deliberately basic per the completion
     *  roadmap's own wording, not a double-entry ledger browser. */
    suspend fun listRecentPayments(limit: Int = 50): AppResult<List<AdminPaymentRecord>>
}
