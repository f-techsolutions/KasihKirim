package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.CarrierProfileDto
import com.ftechsolutions.kasihkirim.domain.model.CarrierProfile
import com.ftechsolutions.kasihkirim.domain.model.NewCarrier
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.repository.CarrierRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException

class CarrierRepositoryImpl : CarrierRepository {

    private val tag = "CarrierRepository"

    override suspend fun getMyCarrierApplication(): AppResult<CarrierProfile?> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        // decodeList().firstOrNull(), not decodeSingleOrNull(): the same
        // reasoning SellerRepositoryImpl.getMySellerApplication documents --
        // only decode methods already proven elsewhere in this module.
        SupabaseClientProvider.client.postgrest.from("carriers")
            .select {
                filter { eq("user_id", userId) }
            }
            .decodeList<CarrierProfileDto>()
            .firstOrNull()
            ?.toDomain()
    }

    override suspend fun applyCarrier(draft: NewCarrier): AppResult<CarrierProfile> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_apply_carrier",
                buildJsonObject { put("p_home_community_id", draft.homeCommunityId) },
            )
            .decodeAs<JsonObject>()
        CarrierProfile(
            id = json.getValue("carrier_id").jsonPrimitive.content,
            status = SellerStatus.fromWire(json.getValue("status").jsonPrimitive.content) ?: SellerStatus.NOT_STARTED,
            homeCommunityId = draft.homeCommunityId,
        )
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "carrier call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toCarrierAppError())
        }
}

private fun Throwable.toCarrierAppError(): AppError = when {
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    message?.contains("CARRIER_APPLICATION_EXISTS", true) == true -> AppError.Server("CARRIER_APPLICATION_EXISTS")
    message?.contains("COMMUNITY_NOT_FOUND", true) == true -> AppError.Server("COMMUNITY_NOT_FOUND")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
