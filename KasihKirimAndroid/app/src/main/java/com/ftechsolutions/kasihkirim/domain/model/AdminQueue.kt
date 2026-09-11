package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors ref.dispute_status exactly (0001_schema.sql). */
enum class DisputeStatus(val wire: String) {
    OPEN("OPEN"),
    UNDER_REVIEW("UNDER_REVIEW"),
    AWAITING_EVIDENCE("AWAITING_EVIDENCE"),
    DECIDED("DECIDED"),
    RESOLVED_REFUND_FULL("RESOLVED_REFUND_FULL"),
    RESOLVED_REFUND_PARTIAL("RESOLVED_REFUND_PARTIAL"),
    RESOLVED_REJECTED("RESOLVED_REJECTED"),
    RESOLVED_SPLIT("RESOLVED_SPLIT"),
    CLOSED("CLOSED");

    val labelMs: String
        get() = when (this) {
            OPEN -> "Dibuka"
            UNDER_REVIEW -> "Dalam Semakan"
            AWAITING_EVIDENCE -> "Menunggu Bukti"
            DECIDED -> "Diputuskan"
            RESOLVED_REFUND_FULL -> "Bayaran Balik Penuh"
            RESOLVED_REFUND_PARTIAL -> "Bayaran Balik Sebahagian"
            RESOLVED_REJECTED -> "Tuntutan Ditolak"
            RESOLVED_SPLIT -> "Kos Dikongsi"
            CLOSED -> "Ditutup"
        }

    /** rpc_admin_resolve_dispute treats exactly these as final: they stamp
     *  resolved_at and clear holds_escrow, which is what lets
     *  fn_settle_delivery run. Anything else is an interim note. */
    val isFinal: Boolean
        get() = this == CLOSED || wire.startsWith("RESOLVED_")

    companion object {
        fun fromWire(value: String): DisputeStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** A seller application waiting on a decision. Distinct from [Seller], which
 *  models the applicant's own view of their single row -- this carries the
 *  reviewer's fields (who applied, what they were last told) and is only ever
 *  readable by an admin, per sellers_select's own is_admin() clause. */
data class SellerApplication(
    val id: String,
    val businessName: String,
    val ssmRegNo: String?,
    val status: SellerStatus,
    val reviewNote: String?,
    val createdAt: String,
)

/** A product waiting on moderation. Only the fields a reviewer decides on --
 *  the seller's own catalogue view is [Product]. */
data class ProductReview(
    val id: String,
    val title: String,
    val description: String?,
    val status: ProductStatus,
    val priceSen: Sen,
    val unit: String,
    val sellerName: String,
    val createdAt: String,
)

data class Dispute(
    val id: String,
    val category: String,
    val description: String,
    val status: DisputeStatus,
    val refundSen: Sen,
    val holdsEscrow: Boolean,
    val resolutionNote: String?,
    val slaDueAt: String,
    val createdAt: String,
)
