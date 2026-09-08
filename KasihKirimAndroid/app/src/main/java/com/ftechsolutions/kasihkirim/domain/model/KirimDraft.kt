package com.ftechsolutions.kasihkirim.domain.model

/** Input to rpc_quote_kirim. Payment method is fixed to COD and
 *  handling_flags/volume_cm3 use the RPC's own defaults for this first
 *  quote-only slice -- rpc_create_kirim (actual submission) doesn't exist
 *  in the backend yet, so this draft is never persisted. */
data class KirimDraft(
    val kirimType: KirimType,
    val category: KirimCategory,
    val estWeightGrams: Int,
    val originNodeId: String,
    val destNodeId: String,
    /** Sen. Only meaningful (and required) when kirimType == BELI. */
    val budgetSen: Long = 0,
)
