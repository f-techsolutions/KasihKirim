package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.DeliveryDto
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.util.UUID

private const val DELIVERY_COLUMNS =
    "id,status,cod_amount_sen,carrier_earning_sen,failure_reason,matched_at," +
        "kirim:kirim_requests(reference_code,item_description,kirim_type)"

class DeliveryRepositoryImpl : DeliveryRepository {

    private val tag = "DeliveryRepository"

    override suspend fun listMyDeliveries(): AppResult<List<Delivery>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("deliveries")
            .select(columns = Columns.raw(DELIVERY_COLUMNS)) {
                order("matched_at", Order.DESCENDING)
            }
            .decodeList<DeliveryDto>()
            .map { it.toDomain() }
    }

    override suspend fun transition(deliveryId: String, event: String): AppResult<KirimStatus> = runCatchingResult {
        // The reified rpc(function, parameters: T) overload isn't in the
        // pinned supabase-bom 3.5.0 -- only rpc(function, JsonObject) exists
        // there (same constraint as every other repository this session).
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_delivery_transition",
                buildJsonObject {
                    put("p_delivery", deliveryId)
                    put("p_event", event)
                    put("p_idempotency_key", UUID.randomUUID().toString())
                },
            )
            .decodeAs<JsonObject>()
        KirimStatus.fromWire(json.getValue("status").jsonPrimitive.content) ?: KirimStatus.MATCHED
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "delivery call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toDeliveryAppError())
        }
}

private fun Throwable.toDeliveryAppError(): AppError = when {
    message?.contains("DELIVERY_NOT_FOUND", true) == true -> AppError.Server("DELIVERY_NOT_FOUND")
    message?.contains("STATE_INVALID_TRANSITION", true) == true -> AppError.Server("STATE_INVALID_TRANSITION")
    message?.contains("STATE_ACTOR_NOT_PERMITTED", true) == true -> AppError.NotAuthorized
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
