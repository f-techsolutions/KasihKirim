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

    /** Matches a POSTED Kirim to one of the caller's own trips
     *  (rpc_accept_offer, 0005_rpc_surface.sql). Capacity is locked and
     *  re-checked server-side; a full trip fails with CAPACITY_EXCEEDED. */
    suspend fun acceptOffer(tripId: String, kirimId: String): AppResult<Unit>
}
