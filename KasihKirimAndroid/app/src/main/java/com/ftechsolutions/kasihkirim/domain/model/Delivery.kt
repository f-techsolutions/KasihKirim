package com.ftechsolutions.kasihkirim.domain.model

/**
 * A row from public.deliveries, joined to its Kirim for display context.
 * deliveries_select's RLS policy already scopes this to the caller's own
 * rows -- carrier_id = my carrier, OR requester_id = me -- so the same
 * unfiltered read serves both a carrier's and a customer's session.
 *
 * [carrierId]/[requesterId] exist so the UI can tell WHICH of those two
 * relationships is the caller's own on this particular delivery -- a
 * dual-role account (e.g. a customer who is also a carrier) can otherwise
 * see the exact same set of rows for either relationship, and account-wide
 * role membership alone can't distinguish "my delivery as carrier" from "my
 * delivery as customer, carried by someone else."
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
    val carrierId: String,
    val requesterId: String,
)
