package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.DealCampaign

/** The buyer-facing read side of the deals gallery (0048). Admin authoring
 *  (rpc_admin_create/update/delete_deal_campaign) has no Android UI --
 *  same reasoning CarrierLotsRepository's admin-review RPCs never appear
 *  here either: the admin console is a separate app. */
interface DealsRepository {
    suspend fun listActiveDeals(): AppResult<List<DealCampaign>>
}
