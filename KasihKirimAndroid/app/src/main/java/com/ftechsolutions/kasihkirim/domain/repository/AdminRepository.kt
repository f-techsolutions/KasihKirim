package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
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
}
