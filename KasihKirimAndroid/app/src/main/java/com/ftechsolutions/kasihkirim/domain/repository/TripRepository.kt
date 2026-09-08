package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.Trip

/**
 * Trip creation goes through rpc_create_trip only (Phase 4 / 0012) -- capacity
 * is derived server-side from the vehicle, never taken from this client. The
 * list read is a direct PostgREST select, scoped to the caller's own trips by
 * trips_select's RLS policy.
 */
interface TripRepository {
    suspend fun listMyTrips(): AppResult<List<Trip>>
    suspend fun createTrip(draft: NewTripDraft): AppResult<Trip>
}
