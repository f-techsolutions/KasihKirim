package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.DeliveryLocation
import com.ftechsolutions.kasihkirim.domain.model.DeliveryTracking
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.TrackingWaypoint
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Decodes rpc_get_delivery_tracking's (0046) JSONB response. */
@Serializable
data class DeliveryTrackingDto(
    @SerialName("delivery_status") val deliveryStatus: String,
    val origin: TrackingWaypointDto? = null,
    val destination: TrackingWaypointDto? = null,
    @SerialName("carrier_location") val carrierLocation: DeliveryLocationDto? = null,
) {
    fun toDomain() = DeliveryTracking(
        deliveryStatus = KirimStatus.fromWire(deliveryStatus) ?: KirimStatus.MATCHED,
        origin = origin?.toDomain(),
        destination = destination?.toDomain(),
        carrierLocation = carrierLocation?.toDomain(),
    )
}

@Serializable
data class TrackingWaypointDto(val name: String, val lat: Double, val lng: Double) {
    fun toDomain() = TrackingWaypoint(name, lat, lng)
}

@Serializable
data class DeliveryLocationDto(
    val lat: Double,
    val lng: Double,
    @SerialName("heading_deg") val headingDeg: Double? = null,
    @SerialName("speed_kmh") val speedKmh: Double? = null,
    @SerialName("accuracy_m") val accuracyM: Double? = null,
    @SerialName("recorded_at") val recordedAt: String,
) {
    fun toDomain() = DeliveryLocation(lat, lng, headingDeg, speedKmh, accuracyM, recordedAt)
}
