package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing

/**
 * Browse-only -- Phase 8. rpc_buy_from_lot exists on the backend but does
 * not enforce ref.compliance_state/ref.feature_gates before moving money,
 * and never persists an order; this repository exposes no purchase method
 * on purpose until that gap closes.
 */
interface MuatanJualRepository {
    suspend fun listLots(): AppResult<List<MuatanJualListing>>
}
