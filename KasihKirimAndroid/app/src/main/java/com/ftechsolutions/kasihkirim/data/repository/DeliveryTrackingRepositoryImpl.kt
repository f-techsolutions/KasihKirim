package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.DeliveryTrackingDto
import com.ftechsolutions.kasihkirim.domain.model.DeliveryTracking
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryTrackingRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.filter.FilterOperator
import io.github.jan.supabase.realtime.PostgresAction
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.postgresChangeFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onStart
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException

class DeliveryTrackingRepositoryImpl : DeliveryTrackingRepository {

    private val tag = "DeliveryTrackingRepository"

    override suspend fun updateMyLocation(
        deliveryId: String,
        lat: Double,
        lng: Double,
        headingDeg: Double?,
        speedKmh: Double?,
        accuracyM: Double?,
    ): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.rpc(
            "rpc_update_delivery_location",
            buildJsonObject {
                put("p_delivery", deliveryId)
                put("p_lat", lat)
                put("p_lng", lng)
                put("p_heading_deg", headingDeg)
                put("p_speed_kmh", speedKmh)
                put("p_accuracy_m", accuracyM)
            },
        )
        Unit
    }

    override suspend fun getTracking(deliveryId: String): AppResult<DeliveryTracking> = runCatchingResult {
        SupabaseClientProvider.client.postgrest
            .rpc("rpc_get_delivery_tracking", buildJsonObject { put("p_delivery", deliveryId) })
            .decodeAs<DeliveryTrackingDto>()
            .toDomain()
    }

    override fun observeLocationChanges(deliveryId: String): Flow<Unit> {
        // One channel per delivery -- channel() returns the existing
        // subscription if this id is already registered (e.g. a second
        // collector while one is still active), so this is safe to call
        // more than once for the same delivery.
        val channel = SupabaseClientProvider.client.channel("delivery_location_$deliveryId")
        return channel.postgresChangeFlow<PostgresAction>(schema = "public") {
            table = "delivery_locations"
            // filter's setter is private in the pinned supabase-bom 3.5.0
            // (made so after the version whose docs first suggested plain
            // assignment) -- this two-arg builder is the only public way
            // to set it in this version.
            filter("delivery_id", FilterOperator.EQ, deliveryId)
        }
            .filter { it is PostgresAction.Insert || it is PostgresAction.Update }
            .map { }
            .onStart { channel.subscribe(blockUntilSubscribed = true) }
            .onCompletion { channel.unsubscribe() }
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "delivery tracking call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toTrackingAppError())
        }
}

private fun Throwable.toTrackingAppError(): AppError = when {
    message?.contains("DELIVERY_NOT_FOUND", true) == true -> AppError.Server("DELIVERY_NOT_FOUND")
    message?.contains("NOT_ASSIGNED_CARRIER", true) == true -> AppError.NotAuthorized
    message?.contains("DELIVERY_NOT_IN_TRANSIT", true) == true -> AppError.Server("DELIVERY_NOT_IN_TRANSIT")
    message?.contains("INVALID_COORDINATES", true) == true -> AppError.Server("INVALID_COORDINATES")
    message?.contains("STATE_ACTOR_NOT_PERMITTED", true) == true -> AppError.NotAuthorized
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
