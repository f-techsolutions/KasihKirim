package com.ftechsolutions.kasihkirim.domain.model

/**
 * A row from public.kirim_requests as shown on the board (carriers browsing
 * POSTED items) or in a requester's own order list. delivery_fee_sen/
 * commission_sen are stored on the row by rpc_create_kirim and shown as-is --
 * Money.kt deliberately offers no arithmetic (no commission helper), so this
 * client displays the two server-computed figures rather than deriving a
 * carrier-earning total itself.
 */
data class KirimSummary(
    val id: String,
    val referenceCode: String,
    val kirimType: KirimType,
    val status: KirimStatus,
    val itemDescription: String,
    val estWeightGrams: Int,
    val originNodeId: String,
    val destNodeId: String,
    val budgetCapSen: Sen?,
    val deliveryFeeSen: Sen?,
    val commissionSen: Sen?,
    val createdAt: String,
)
