package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.DealCampaignDto
import com.ftechsolutions.kasihkirim.domain.model.DealCampaign
import com.ftechsolutions.kasihkirim.domain.repository.DealsRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import java.io.IOException

class DealsRepositoryImpl : DealsRepository {

    private val tag = "DealsRepository"

    override suspend fun listActiveDeals(): AppResult<List<DealCampaign>> = try {
        val deals = SupabaseClientProvider.client.postgrest.from("v_deal_campaigns")
            .select {
                order("sort_order", Order.ASCENDING)
            }
            .decodeList<DealCampaignDto>()
            .map { it.toDomain() }
        AppResult.Success(deals)
    } catch (t: Throwable) {
        SafeLog.e(tag, "listActiveDeals failed: ${t::class.simpleName}", t)
        AppResult.Failure(t.toDealsAppError())
    }
}

private fun Throwable.toDealsAppError(): AppError = when {
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
