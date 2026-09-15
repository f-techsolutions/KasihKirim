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

/** A carrier application waiting on a decision. Distinct from [CarrierProfile],
 *  which models the applicant's own view of their single row -- mirrors
 *  [SellerApplication]'s own split for the same reason: only an admin can
 *  read another user's review_note, per carriers_select's is_admin() clause. */
data class CarrierApplication(
    val id: String,
    val status: SellerStatus,
    val homeCommunityName: String?,
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

/** Mirrors ref.account_status exactly (0001_schema.sql / public.profiles.status).
 *  Unlike [SellerStatus], this has never had any server-side effect beyond
 *  display until 0041_account_management.sql made custom_access_token_hook
 *  actually refuse to mint a token for SUSPENDED/BANNED/DELETED -- setting
 *  it before that migration was cosmetic record-keeping only. */
enum class AccountStatus(val wire: String) {
    PENDING("pending"),
    ACTIVE("active"),
    SUSPENDED("suspended"),
    BANNED("banned"),
    DELETED("deleted");

    val labelMs: String
        get() = when (this) {
            PENDING -> "Menunggu"
            ACTIVE -> "Aktif"
            SUSPENDED -> "Digantung"
            BANNED -> "Disekat"
            DELETED -> "Dipadam"
        }

    companion object {
        fun fromWire(value: String): AccountStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** A search result row in the admin account-management screen -- not a
 *  queue (nothing about "search" narrows to a pending count the way the
 *  seller/carrier/product/dispute tabs do), just profiles read as a
 *  reviewer, per profiles_select's own is_admin() clause (0003). */
data class AdminAccount(
    val id: String,
    val phone: String,
    val fullName: String?,
    val displayName: String?,
    val status: AccountStatus,
    val suspendedReason: String?,
    val createdAt: String,
)
