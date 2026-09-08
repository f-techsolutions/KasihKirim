package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import java.io.IOException

class EarningsRepositoryImpl : EarningsRepository {

    private val tag = "EarningsRepository"

    override suspend fun myEarnings(): AppResult<Earnings> =
        try {
            // rpc_my_earnings takes no parameters, but the reified
            // rpc(function, parameters: T) overload isn't in the pinned
            // supabase-bom 3.5.0 -- only rpc(function, JsonObject) exists
            // there (same constraint as KirimRepositoryImpl/AddressRepositoryImpl),
            // so an empty JsonObject stands in for "no arguments".
            val json = SupabaseClientProvider.client.postgrest
                .rpc("rpc_my_earnings", buildJsonObject {})
                .decodeAs<JsonObject>()
            AppResult.Success(json.toEarnings())
        } catch (t: Throwable) {
            SafeLog.e(tag, "earnings call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toEarningsAppError())
        }
}

private fun JsonObject.toEarnings() = Earnings(
    availableSen = Sen(getValue("available_sen").jsonPrimitive.long),
    pendingSen = Sen(getValue("pending_sen").jsonPrimitive.long),
    codHeldSen = this["cod_held_sen"]?.jsonPrimitive?.long?.let(::Sen),
    floatLimitSen = this["float_limit_sen"]?.jsonPrimitive?.long?.let(::Sen),
)

private fun Throwable.toEarningsAppError(): AppError = when {
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
