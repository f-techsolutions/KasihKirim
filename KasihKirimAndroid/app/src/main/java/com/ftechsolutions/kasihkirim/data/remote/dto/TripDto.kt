package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.trips (0001_schema.sql), columns this client reads
 *  for the carrier's own trip list. */
@Serializable
data class TripDto(
    val id: String,
    val status: String,
    @SerialName("origin_node_id") val originNodeId: String,
    @SerialName("dest_node_id") val destNodeId: String,
    @SerialName("depart_at") val departAt: String,
    @SerialName("capacity_weight_grams") val capacityWeightGrams: Int,
    @SerialName("capacity_volume_cm3") val capacityVolumeCm3: Int,
    @SerialName("capacity_parcels") val capacityParcels: Int,
    @SerialName("reserved_weight_grams") val reservedWeightGrams: Int,
    @SerialName("reserved_volume_cm3") val reservedVolumeCm3: Int,
    @SerialName("reserved_parcels") val reservedParcels: Int,
) {
    fun toDomain() = Trip(
        id = id,
        status = TripStatus.fromWire(status) ?: TripStatus.DRAFT,
        originNodeId = originNodeId,
        destNodeId = destNodeId,
        departAt = departAt,
        capacityWeightGrams = capacityWeightGrams,
        capacityVolumeCm3 = capacityVolumeCm3,
        capacityParcels = capacityParcels,
        reservedWeightGrams = reservedWeightGrams,
        reservedVolumeCm3 = reservedVolumeCm3,
        reservedParcels = reservedParcels,
    )
}
