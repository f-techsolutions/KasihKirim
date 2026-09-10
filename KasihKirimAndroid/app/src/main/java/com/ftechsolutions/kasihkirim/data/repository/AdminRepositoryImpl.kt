package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.DisputeDto
import com.ftechsolutions.kasihkirim.data.remote.dto.ProductReviewDto
import com.ftechsolutions.kasihkirim.data.remote.dto.SellerApplicationDto
import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
import com.ftechsolutions.kasihkirim.domain.model.ProductReview
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.SellerApplication
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.repository.AdminRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException

private const val SELLER_APPLICATION_COLUMNS =
    "id,business_name,ssm_reg_no,status,review_note,created_at"

private const val PRODUCT_REVIEW_COLUMNS =
    "id,title,description,status,price_sen,unit,created_at,sellers(business_name)"

private const val DISPUTE_COLUMNS =
    "id,category,description,status,refund_sen,holds_escrow,resolution_note,sla_due_at,created_at"

/** Statuses that still need a decision from a reviewer. */
private val SELLER_QUEUE = setOf(
    SellerStatus.NOT_STARTED,
    SellerStatus.SUBMITTED,
    SellerStatus.UNDER_REVIEW,
    SellerStatus.MORE_INFO_REQUIRED,
)

private val PRODUCT_QUEUE = setOf(ProductStatus.DRAFT, ProductStatus.PENDING_REVIEW)

class AdminRepositoryImpl : AdminRepository {

    private val tag = "AdminRepository"

    // The queue filters below run client-side. Postgrest-kt's `isIn` has no
    // working example anywhere in this module, and the review queues are
    // bounded by how fast a human can clear them -- so this fetches what RLS
    // already scopes to an admin and narrows it here, rather than being the
    // first call site to guess at an untested filter method's signature.

    override suspend fun listSellerApplications(): AppResult<List<SellerApplication>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("sellers")
            .select(columns = Columns.raw(SELLER_APPLICATION_COLUMNS)) {
                order("created_at", Order.ASCENDING)
            }
            .decodeList<SellerApplicationDto>()
            .map { it.toDomain() }
            .filter { it.status in SELLER_QUEUE }
    }

    override suspend fun setSellerStatus(
        sellerId: String,
        status: SellerStatus,
        reason: String?,
    ): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.rpc(
            "rpc_admin_set_seller_status",
            buildJsonObject {
                put("p_seller_id", sellerId)
                put("p_status", status.wire)
                put("p_reason", reason)
            },
        )
        Unit
    }

    override suspend fun listProductReviews(): AppResult<List<ProductReview>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("products")
            .select(columns = Columns.raw(PRODUCT_REVIEW_COLUMNS)) {
                filter { exact("deleted_at", null) }
                order("created_at", Order.ASCENDING)
            }
            .decodeList<ProductReviewDto>()
            .map { it.toDomain() }
            .filter { it.status in PRODUCT_QUEUE }
    }

    override suspend fun setProductStatus(
        productId: String,
        status: ProductStatus,
        rejectionReason: String?,
    ): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.rpc(
            "rpc_admin_set_product_status",
            buildJsonObject {
                put("p_product_id", productId)
                put("p_status", status.wire)
                put("p_rejection_reason", rejectionReason)
            },
        )
        Unit
    }

    override suspend fun listOpenDisputes(): AppResult<List<Dispute>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("disputes")
            .select(columns = Columns.raw(DISPUTE_COLUMNS)) {
                order("created_at", Order.ASCENDING)
            }
            .decodeList<DisputeDto>()
            .map { it.toDomain() }
            .filter { !it.status.isFinal }
    }

    override suspend fun resolveDispute(
        disputeId: String,
        status: DisputeStatus,
        note: String?,
        refundSen: Long,
    ): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.rpc(
            "rpc_admin_resolve_dispute",
            buildJsonObject {
                put("p_dispute_id", disputeId)
                put("p_status", status.wire)
                put("p_note", note)
                put("p_refund_sen", refundSen)
            },
        )
        Unit
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "admin call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toAdminAppError())
        }
}

private fun Throwable.toAdminAppError(): AppError = when {
    // The server's own name for "you are not an admin" -- raised by every
    // rpc_admin_* function before it touches a row.
    message?.contains("STATE_ACTOR_NOT_PERMITTED", true) == true -> AppError.NotAuthorized
    message?.contains("SELLER_NOT_FOUND", true) == true -> AppError.Server("SELLER_NOT_FOUND")
    message?.contains("PRODUCT_NOT_FOUND", true) == true -> AppError.Server("PRODUCT_NOT_FOUND")
    message?.contains("DISPUTE_NOT_FOUND", true) == true -> AppError.Server("DISPUTE_NOT_FOUND")
    message?.contains("INVALID_STATUS", true) == true -> AppError.Server("INVALID_STATUS")
    message?.contains("INVALID_REFUND", true) == true -> AppError.Server("INVALID_REFUND")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
