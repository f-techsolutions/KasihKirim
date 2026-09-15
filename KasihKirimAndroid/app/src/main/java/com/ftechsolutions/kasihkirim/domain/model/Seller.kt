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

/** Mirrors ref.seller_onboarding_status exactly (0007_sabah_geography_
 *  compliance.sql). A separate track from [SellerStatus] above -- that one
 *  gates the general Jualan marketplace (rpc_admin_set_seller_status,
 *  0023); this one gates Muatan Jual specifically (a carrier selling their
 *  own carried stock), reviewed by rpc_admin_review_muatan_jual_seller and
 *  accepted by the seller themselves via rpc_accept_muatan_jual_terms
 *  (0047). A sellers row always has both, independently. */
enum class MuatanJualOnboardingStatus(val wire: String) {
    PENDING("PENDING"),
    DOCUMENT_REVIEW("DOCUMENT_REVIEW"),
    APPROVED("APPROVED"),
    ACTIVE("ACTIVE"),
    REJECTED("REJECTED"),
    SUSPENDED("SUSPENDED"),
    EXPIRED("EXPIRED");

    val labelMs: String
        get() = when (this) {
            PENDING -> "Menunggu Semakan"
            DOCUMENT_REVIEW -> "Dokumen Disemak"
            APPROVED -> "Diluluskan -- Sila Terima Terma"
            ACTIVE -> "Aktif"
            REJECTED -> "Ditolak"
            SUSPENDED -> "Digantung"
            EXPIRED -> "Tamat Tempoh"
        }

    companion object {
        fun fromWire(value: String): MuatanJualOnboardingStatus? = entries.firstOrNull { it.wire == value }
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
    val sellerKind: String = "individual",
    val onboardingStatus: MuatanJualOnboardingStatus = MuatanJualOnboardingStatus.PENDING,
)

/** A seller application the user is composing -- rpc_apply_seller's params,
 *  1:1. sellerKind defaults to 'individual' (the sellers table's own DDL
 *  default); a carrier applying specifically for Muatan Jual passes
 *  'carrier_trader' (FR-440 -- no new identity model, the same RPC). */
data class NewSeller(
    val businessName: String,
    val communityId: String,
    val ssmRegNo: String?,
    val sellerKind: String = "individual",
)
