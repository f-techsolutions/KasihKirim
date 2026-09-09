package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.TripDto
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException
import java.util.UUID

private const val TRIP_COLUMNS =
    "id,status,origin_node_id,dest_node_id,depart_at,capacity_weight_grams," +
        "capacity_volume_cm3,capacity_parcels,reserved_weight_grams," +
        "reserved_volume_cm3,reserved_parcels"

class TripRepositoryImpl : TripRepository {

    private val tag = "TripRepository"

    override suspend fun listMyTrips(): AppResult<List<Trip>> = runCatchingResult {
        val carrierId = requireCarrierId()
        SupabaseClientProvider.client.postgrest.from("trips")
            .select(columns = Columns.raw(TRIP_COLUMNS)) {
                filter { eq("carrier_id", carrierId) }
                order("depart_at", Order.DESCENDING)
            }
            .decodeList<TripDto>()
            .map { it.toDomain() }
    }

    override suspend fun createTrip(draft: NewTripDraft): AppResult<Trip> = runCatchingResult {
        // The reified rpc(function, parameters: T) overload isn't in the
        // pinned supabase-bom 3.5.0 -- only rpc(function, JsonObject) exists
        // there (same constraint as Kirim/Address/Earnings repositories).
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_create_trip",
                buildJsonObject {
                    put("p_vehicle_id", draft.vehicleId)
                    put("p_origin_node", draft.originNodeId)
                    put("p_dest_node", draft.destNodeId)
                    put("p_depart_at", draft.departAtIso)
                },
            )
            .decodeAs<JsonObject>()
        val tripId = (json["trip_id"] as JsonPrimitive).content
        // rpc_create_trip's own response is a confirmation summary, not the
        // full row -- fetch it back the same way listMyTrips reads any trip.
        SupabaseClientProvider.client.postgrest.from("trips")
            .select(columns = Columns.raw(TRIP_COLUMNS)) {
                filter { eq("id", tripId) }
            }
            .decodeSingle<TripDto>()
            .toDomain()
    }

    override suspend fun acceptOffer(tripId: String, kirimId: String): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_accept_offer",
                buildJsonObject {
                    put("p_trip", tripId)
                    put("p_kirim", kirimId)
                    put("p_idempotency_key", UUID.randomUUID().toString())
                },
            )
        Unit
    }

    /** carrier_id lives only in the JWT the hook mints, never in the SDK's
     *  cached user object -- see SupabaseClientProvider.currentJwtAppMetadata(). */
    private fun requireCarrierId(): String {
        val meta: JsonObject? = SupabaseClientProvider.currentJwtAppMetadata()
        return (meta?.get("carrier_id") as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() && it != "null" }
            ?: throw IllegalStateException("NOT_A_CARRIER")
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "trip call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toTripAppError())
        }
}

private fun Throwable.toTripAppError(): AppError = when {
    message?.contains("NOT_A_CARRIER", true) == true -> AppError.NotAuthorized
    message?.contains("VEHICLE_NOT_FOUND", true) == true -> AppError.Server("VEHICLE_NOT_FOUND")
    message?.contains("INVALID_CORRIDOR", true) == true -> AppError.Server("INVALID_CORRIDOR")
    message?.contains("DEPART_TIME_IN_PAST", true) == true -> AppError.Server("DEPART_TIME_IN_PAST")
    message?.contains("STATE_ACTOR_NOT_PERMITTED", true) == true -> AppError.NotAuthorized
    message?.contains("STATE_INVALID_TRANSITION", true) == true -> AppError.Server("STATE_INVALID_TRANSITION")
    message?.contains("SELF_DEALING", true) == true -> AppError.Server("SELF_DEALING")
    message?.contains("FLOAT_LIMIT_EXCEEDED", true) == true -> AppError.Server("FLOAT_LIMIT_EXCEEDED")
    message?.contains("CAPACITY_EXCEEDED", true) == true -> AppError.Server("CAPACITY_EXCEEDED")
    message?.contains("TRIP_NOT_FOUND", true) == true -> AppError.Server("TRIP_NOT_FOUND")
    message?.contains("TRIP_NOT_BOARDING", true) == true -> AppError.Server("TRIP_NOT_BOARDING")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
