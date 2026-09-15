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

    /** Ajak Kirim (rpc_send_capacity_invite, 0006_carrier_commerce.sql).
     *  Always targets 'past_senders' -- people who have sent through this
     *  carrier before -- so sending an invite is a single tap with no
     *  community picker or message form. Returns how many people it
     *  actually reached (FR-404's own 24h-per-recipient cap can make this
     *  0 even on success). */
    suspend fun sendCapacityInvite(tripId: String): AppResult<Int>
}
