package com.ftechsolutions.kasihkirim.domain.model

/** Which ledger balance a withdrawal draws from -- rpc_request_withdrawal's
 *  own p_payee_type (0042_carrier_seller_payouts.sql, extended for
 *  'promoter' by 0045_kongsi_untung_promotions.sql). 'agent' exists in
 *  internal.payouts' own CHECK but has no client-facing app, so it is not
 *  modelled here. */
enum class PayeeType(val wire: String) {
    CARRIER("carrier"),
    SELLER("seller"),
    PROMOTER("promoter"),
}

/** Mirrors ref.payout_status exactly (0001_schema.sql). BATCHED/PROCESSING
 *  are never produced by this phase's stub flow (see 0042's own header
 *  comment) -- they are modelled here only so a future real disbursement
 *  integration does not need a client-side enum change to show them. */
enum class PayoutStatus(val wire: String) {
    REQUESTED("REQUESTED"),
    UNDER_REVIEW("UNDER_REVIEW"),
    APPROVED("APPROVED"),
    REJECTED("REJECTED"),
    BATCHED("BATCHED"),
    PROCESSING("PROCESSING"),
    PAID("PAID"),
    FAILED("FAILED");

    val labelMs: String
        get() = when (this) {
            REQUESTED -> "Diminta"
            UNDER_REVIEW -> "Dalam Semakan"
            APPROVED -> "Diluluskan"
            REJECTED -> "Ditolak"
            BATCHED -> "Dalam Kelompok"
            PROCESSING -> "Diproses"
            PAID -> "Selesai"
            FAILED -> "Gagal"
        }

    companion object {
        fun fromWire(value: String): PayoutStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** rpc_my_bank_accounts's own row shape -- account_no_last4 is the only
 *  form of the account number this client (or this phase's admin console)
 *  ever sees; the full number is encrypted server-side with no decrypt
 *  path exposed anywhere yet. */
data class BankAccount(
    val id: String,
    val bankCode: String,
    val accountNoLast4: String,
    val holderName: String,
    val verifiedAt: String?,
    val createdAt: String,
)

/** A withdrawal as its own requester sees it -- rpc_my_payouts. */
data class PayoutRequest(
    val id: String,
    val payeeType: String,
    val amountSen: Sen,
    val status: PayoutStatus,
    val bankCode: String,
    val accountNoLast4: String,
    val requestedAt: String,
    val paidAt: String?,
    val failureReason: String?,
)

/** A withdrawal as an admin sees it -- rpc_admin_list_payouts. Only ever
 *  the actionable set (REQUESTED through PROCESSING), same as this file's
 *  other admin queues -- see that RPC's own comment. */
data class AdminPayout(
    val id: String,
    val payeeType: String,
    val payeeLabel: String?,
    val amountSen: Sen,
    val status: PayoutStatus,
    val bankCode: String,
    val accountNoLast4: String,
    val holderName: String,
    val reviewedBy: String?,
    val approvedBy: String?,
    val requestedAt: String,
)
