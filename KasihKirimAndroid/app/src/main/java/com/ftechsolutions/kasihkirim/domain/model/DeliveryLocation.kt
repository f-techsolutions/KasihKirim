package com.ftechsolutions.kasihkirim.domain.model

/** The statuses in which a delivery is actually being carried -- the same
 *  window rpc_update_delivery_location (0046) accepts a position write for,
 *  mirrored here so the UI offers "share/track" only when a write would
 *  actually succeed. */
val TRACKABLE_DELIVERY_STATUSES = setOf(
    KirimStatus.PICKED_UP, KirimStatus.IN_TRANSIT, KirimStatus.AT_HUB, KirimStatus.OUT_FOR_DELIVERY,
)

/** A carrier's last known position for one delivery -- public.delivery_locations
 *  (0046), one row per delivery, upserted. */
data class DeliveryLocation(
    val lat: Double,
    val lng: Double,
    val headingDeg: Double?,
    val speedKmh: Double?,
    val accuracyM: Double?,
    val recordedAt: String,
)

/** A named point resolved from ref.route_nodes -- a kirim's origin or
 *  destination, for bounding the tracking screen's display. */
data class TrackingWaypoint(val name: String, val lat: Double, val lng: Double)

/** rpc_get_delivery_tracking's (0046) full response: the delivery's current
 *  status, its origin/destination, and the carrier's live position if one has
 *  been posted yet. */
data class DeliveryTracking(
    val deliveryStatus: KirimStatus,
    val origin: TrackingWaypoint?,
    val destination: TrackingWaypoint?,
    val carrierLocation: DeliveryLocation?,
)
