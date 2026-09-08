package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.NewVehicle
import com.ftechsolutions.kasihkirim.domain.model.Vehicle

/**
 * public.vehicles is RLS-scoped to "own" for select/insert/update/delete
 * (vehicles_own, 0003_functions_rls.sql), but a real DELETE risks an FK
 * violation the moment any trip references the vehicle -- setVehicleActive
 * is the only removal path this repository exposes, matching the "soft
 * delete only" shape already used for addresses.
 */
interface VehicleRepository {
    suspend fun listVehicles(): AppResult<List<Vehicle>>
    suspend fun createVehicle(draft: NewVehicle): AppResult<Vehicle>
    suspend fun updateVehicle(id: String, draft: NewVehicle): AppResult<Vehicle>
    suspend fun setVehicleActive(id: String, isActive: Boolean): AppResult<Unit>
}
