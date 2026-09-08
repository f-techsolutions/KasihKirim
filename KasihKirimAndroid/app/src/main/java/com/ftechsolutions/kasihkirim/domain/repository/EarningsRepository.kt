package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Earnings

/**
 * Display only -- Phase 7 / §31. rpc_my_earnings is the sole read here, and
 * this repository exposes no write: there is no mutation path to money from
 * this client, on purpose.
 */
interface EarningsRepository {
    suspend fun myEarnings(): AppResult<Earnings>
}
