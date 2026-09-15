package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.DeliveryTracking
import kotlinx.coroutines.flow.Flow

interface DeliveryTrackingRepository {
    /** rpc_update_delivery_location (0046). The assigned carrier's own write
     *  path for their current position -- the server refuses this outside
     *  TRACKABLE_DELIVERY_STATUSES and for anyone but the assigned carrier. */
    suspend fun updateMyLocation(
        deliveryId: String,
        lat: Double,
        lng: Double,
        headingDeg: Double? = null,
        speedKmh: Double? = null,
        accuracyM: Double? = null,
    ): AppResult<Unit>

    /** rpc_get_delivery_tracking (0046): the delivery's status, its
     *  origin/destination, and the carrier's last known position, if any. */
    suspend fun getTracking(deliveryId: String): AppResult<DeliveryTracking>

    /** Emits once per postgres_changes INSERT/UPDATE on this delivery's own
     *  delivery_locations row -- a pulse, not the row's data. The row's geog
     *  column is a PostGIS GEOGRAPHY value; Realtime's own change payload
     *  serializes it as raw EWKB (not JSON), so it isn't decodable into
     *  lat/lng on-device without a WKB parser. The caller re-fetches via
     *  [getTracking] instead, whose SQL-side ST_Y/ST_X extraction is the one
     *  path already covered by 36_live_delivery_tracking.test.sql. */
    fun observeLocationChanges(deliveryId: String): Flow<Unit>
}
