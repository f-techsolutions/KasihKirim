package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.DeliveryDto
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.storage.storage
import io.ktor.client.request.header
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.time.Instant
import java.util.UUID

private const val DELIVERY_COLUMNS =
    "id,status,cod_amount_sen,carrier_earning_sen,failure_reason,matched_at," +
        "kirim:kirim_requests(reference_code,item_description,kirim_type)"

private const val POD_BUCKET = "pod"

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

    override suspend fun submitProofAndTransition(
        deliveryId: String,
        leg: String,
        event: String,
        photoBytes: ByteArray,
    ): AppResult<KirimStatus> = runCatchingResult {
        // First path segment must equal the delivery id -- storage RLS
        // (pod_insert_assigned_carrier) checks exactly that:
        // (storage.foldername(objects.name))[1] = d.id::text.
        val path = "$deliveryId/${leg}_${System.currentTimeMillis()}.jpg"

        // TEMPORARY DIAGNOSTIC for the anon-role upload bug -- read via the
        // Supabase Storage Logs dashboard on req.headers, not device logcat.
        // Remove once the root cause of the Storage 400s is confirmed.
        val authPlugin = SupabaseClientProvider.client.auth
        val debugSession = authPlugin.currentSessionOrNull()
        val debugExpiresInSec = debugSession?.let {
            (it.expiresAt - kotlinx.datetime.Clock.System.now()).inWholeSeconds
        }
        SupabaseClientProvider.client.storage.from(POD_BUCKET).upload(path, photoBytes) {
            httpOverride {
                header("x-debug-token-present", (debugSession != null).toString())
                header("x-debug-token-expires-in-sec", debugExpiresInSec?.toString() ?: "no-session")
            }
        }

        SupabaseClientProvider.client.postgrest.rpc(
            "rpc_submit_proof",
            buildJsonObject {
                put("p_delivery", deliveryId)
                put("p_leg", leg)
                put("p_method", "PHOTO")
                put("p_captured_at", Instant.now().toString())
                put("p_photo_path", path)
            },
        )

        // internal.fn_delivery_transition refuses this event with
        // PROOF_REQUIRED unless the proofs row inserted above already
        // exists -- these two calls are not reorderable.
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
    // rpc_submit_proof / internal.fn_delivery_transition (proof leg).
    message?.contains("NOT_ASSIGNED_CARRIER", true) == true -> AppError.NotAuthorized
    message?.contains("PHOTO_PATH_REQUIRED", true) == true -> AppError.Server("PHOTO_PATH_REQUIRED")
    message?.contains("PROOF_REQUIRED", true) == true -> AppError.Server("PROOF_REQUIRED")
    message?.contains("STATE_ACTOR_NOT_PERMITTED", true) == true -> AppError.NotAuthorized
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
