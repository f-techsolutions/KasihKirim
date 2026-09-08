package com.ftechsolutions.kasihkirim.domain.model

/**
 * A row from public.deliveries, joined to its Kirim for display context.
 * deliveries_select's RLS policy already scopes this to the caller's own
 * rows -- carrier_id = my carrier, OR requester_id = me -- so the same
 * unfiltered read serves both a carrier's and a customer's session.
 */
data class Delivery(
    val id: String,
    val status: KirimStatus,
    val kirimType: KirimType,
    val referenceCode: String,
    val itemDescription: String,
    val codAmountSen: Sen,
    val carrierEarningSen: Sen?,
    val failureReason: String?,
    val matchedAt: String,
)
