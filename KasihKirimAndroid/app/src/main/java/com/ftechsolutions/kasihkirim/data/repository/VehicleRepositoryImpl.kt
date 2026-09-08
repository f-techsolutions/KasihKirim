package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.VehicleActiveUpdateDto
import com.ftechsolutions.kasihkirim.data.remote.dto.VehicleDto
import com.ftechsolutions.kasihkirim.data.remote.dto.toDto
import com.ftechsolutions.kasihkirim.data.remote.dto.toUpdateDto
import com.ftechsolutions.kasihkirim.domain.model.NewVehicle
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.IOException

private const val VEHICLE_COLUMNS =
    "id,vehicle_type,plate_no,make_model,capacity_weight_grams,capacity_volume_cm3," +
        "capacity_parcels,is_active"

class VehicleRepositoryImpl : VehicleRepository {

    private val tag = "VehicleRepository"

    override suspend fun listVehicles(): AppResult<List<Vehicle>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("vehicles")
            .select(columns = Columns.raw(VEHICLE_COLUMNS)) {
                filter { eq("carrier_id", requireCarrierId()) }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<VehicleDto>()
            .map { it.toDomain() }
    }

    override suspend fun createVehicle(draft: NewVehicle): AppResult<Vehicle> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("vehicles")
            .insert(draft.toDto(requireCarrierId())) { select(columns = Columns.raw(VEHICLE_COLUMNS)) }
            .decodeSingle<VehicleDto>()
            .toDomain()
    }

    override suspend fun updateVehicle(id: String, draft: NewVehicle): AppResult<Vehicle> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("vehicles")
            .update(draft.toUpdateDto()) {
                filter { eq("id", id) }
                select(columns = Columns.raw(VEHICLE_COLUMNS))
            }
            .decodeSingle<VehicleDto>()
            .toDomain()
    }

    override suspend fun setVehicleActive(id: String, isActive: Boolean): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("vehicles")
            .update(VehicleActiveUpdateDto(isActive)) { filter { eq("id", id) } }
        Unit
    }

    /** carrier_id is a JWT app_metadata claim (custom_access_token_hook),
     *  the same one authz.my_carrier_id() reads server-side -- never guessed
     *  or read from a table. Absent means the account isn't an approved
     *  carrier, which the caller should not have reached this far without. */
    private fun requireCarrierId(): String {
        val meta: JsonObject? = SupabaseClientProvider.client.auth.currentUserOrNull()?.appMetadata
        return (meta?.get("carrier_id") as? JsonPrimitive)?.content?.takeIf { it.isNotBlank() && it != "null" }
            ?: throw IllegalStateException("NOT_A_CARRIER")
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "vehicle call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toVehicleAppError())
        }
}

private fun Throwable.toVehicleAppError(): AppError = when {
    message?.contains("NOT_A_CARRIER", true) == true -> AppError.NotAuthorized
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
