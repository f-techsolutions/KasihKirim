package com.ftechsolutions.kasihkirim.domain.model

/** The exact response shape of public.rpc_quote_kirim (0005_rpc_surface.sql).
 *  carrier_earning_sen is returned on purpose (FR-245): a carrier must see
 *  what they will earn before accepting -- Android just carries it through. */
data class KirimQuote(
    val quoteId: String,
    val expiresAt: String,
    val corridorKm: Double,
    val corridorBand: String,
    val goodsBudgetSen: Sen,
    val deliveryFeeSen: Sen,
    val commissionSen: Sen,
    val orderTotalSen: Sen,
    val carrierEarningSen: Sen,
    val pricingRuleVersion: Int,
)
