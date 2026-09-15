package com.ftechsolutions.kasihkirim.domain.model

/**
 * rpc_admin_search_order's (0043_admin_order_search_and_ledger_view.sql) own
 * result shape -- one search box, one result, since reference codes are
 * UNIQUE on both kirim_requests and orders. [order] is populated only for a
 * PASARAN kirim (it wraps a marketplace order); [payment] is null whenever
 * the kirim is COD and hasn't opened an internal.payments row yet, which is
 * the normal state for most of a Kirim's life, not a lookup failure.
 */
data class AdminOrderSearchResult(
    val kirimId: String,
    val referenceCode: String,
    val kirimType: KirimType,
    val status: KirimStatus?,
    val itemDescription: String,
    val estWeightGrams: Int,
    val budgetCapSen: Sen?,
    val deliveryFeeSen: Sen?,
    val commissionSen: Sen?,
    val totalEscrowSen: Sen?,
    val paymentMethod: String?,
    val createdAt: String,
    val requesterName: String?,
    val requesterPhone: String?,
    val order: AdminOrderSummary?,
    val payment: AdminPaymentSummary?,
    val deliveries: List<AdminDeliveryAttempt>,
)

data class AdminOrderSummary(
    val id: String,
    val referenceCode: String,
    val status: String,
    val goodsSubtotalSen: Sen,
    val deliveryFeeSen: Sen,
    val discountSen: Sen,
    val commissionSen: Sen,
    val totalSen: Sen,
    val createdAt: String,
)

/** internal.payments is never exposed to a client directly (0000_prelude.sql
 *  revokes schema `internal` from anon/authenticated entirely) -- status and
 *  method are shown as the server's own words rather than mapped through a
 *  client-side enum, same reasoning as the deliberately-basic ledger view. */
data class AdminPaymentSummary(
    val id: String,
    val provider: String,
    val method: String,
    val amountSen: Sen,
    val status: String,
    val failureCode: String?,
    val createdAt: String,
)

data class AdminDeliveryAttempt(
    val id: String,
    val attemptNo: Int,
    val status: KirimStatus?,
    val carrierName: String?,
    val carrierPhone: String?,
    val codAmountSen: Sen,
    val carrierEarningSen: Sen?,
    val failureReason: String?,
    val matchedAt: String?,
    val pickedUpAt: String?,
    val deliveredAt: String?,
    val completedAt: String?,
    val hasOpenDispute: Boolean,
)

/** rpc_admin_recent_payments's (0043) own row shape -- the platform's most
 *  recent payment activity, newest first. Deliberately basic per the
 *  roadmap's own wording, not a double-entry ledger browser: internal's own
 *  ledger_transactions/ledger_entries stay unexposed. */
data class AdminPaymentRecord(
    val id: String,
    val referenceType: String,
    val referenceId: String,
    val payerName: String?,
    val payerPhone: String?,
    val provider: String,
    val method: String,
    val amountSen: Sen,
    val status: String,
    val failureCode: String?,
    val createdAt: String,
)
