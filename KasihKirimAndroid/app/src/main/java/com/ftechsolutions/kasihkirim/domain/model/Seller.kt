package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors ref.verification_status exactly (0016_seller_onboarding.sql /
 *  public.sellers.status). The same enum type carriers/agents use. */
enum class SellerStatus(val wire: String) {
    NOT_STARTED("NOT_STARTED"),
    SUBMITTED("SUBMITTED"),
    UNDER_REVIEW("UNDER_REVIEW"),
    MORE_INFO_REQUIRED("MORE_INFO_REQUIRED"),
    APPROVED("APPROVED"),
    REJECTED("REJECTED"),
    SUSPENDED("SUSPENDED"),
    REVOKED("REVOKED");

    val labelMs: String
        get() = when (this) {
            NOT_STARTED -> "Belum Bermula"
            SUBMITTED -> "Telah Dihantar"
            UNDER_REVIEW -> "Dalam Semakan"
            MORE_INFO_REQUIRED -> "Maklumat Tambahan Diperlukan"
            APPROVED -> "Diluluskan"
            REJECTED -> "Ditolak"
            SUSPENDED -> "Digantung"
            REVOKED -> "Dibatalkan"
        }

    /** Presentation only -- whether the applicant can still expect to sell,
     *  used to choose which screen state to render. */
    val isUsable: Boolean get() = this == APPROVED

    companion object {
        fun fromWire(value: String): SellerStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** public.sellers -- only the columns this client reads or writes.
 *  commission_bps/rating_avg/verified_at are admin/marketplace concerns not
 *  surfaced in the seller-facing Jualan screen yet. */
data class Seller(
    val id: String,
    val businessName: String,
    val status: SellerStatus,
    val communityId: String,
    val ssmRegNo: String?,
)

/** A seller application the user is composing -- rpc_apply_seller's params,
 *  1:1. */
data class NewSeller(
    val businessName: String,
    val communityId: String,
    val ssmRegNo: String?,
)
