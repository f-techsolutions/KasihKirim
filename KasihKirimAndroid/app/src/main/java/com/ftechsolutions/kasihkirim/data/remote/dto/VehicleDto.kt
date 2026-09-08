package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.NewVehicle
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.model.VehicleType
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.vehicles (0001_schema.sql). */
@Serializable
data class VehicleDto(
    val id: String,
    @SerialName("vehicle_type") val vehicleType: String,
    @SerialName("plate_no") val plateNo: String? = null,
    @SerialName("make_model") val makeModel: String? = null,
    @SerialName("capacity_weight_grams") val capacityWeightGrams: Int,
    @SerialName("capacity_volume_cm3") val capacityVolumeCm3: Int,
    @SerialName("capacity_parcels") val capacityParcels: Int,
    @SerialName("is_active") val isActive: Boolean,
) {
    fun toDomain() = Vehicle(
        id = id,
        vehicleType = VehicleType.fromWire(vehicleType) ?: VehicleType.CAR,
        plateNo = plateNo,
        makeModel = makeModel,
        capacityWeightGrams = capacityWeightGrams,
        capacityVolumeCm3 = capacityVolumeCm3,
        capacityParcels = capacityParcels,
        isActive = isActive,
    )
}

/** Insert body for public.vehicles. carrier_id is set from the JWT's own
 *  carrier_id claim (AuthUser.carrierId), never guessed -- vehicles_own's
 *  WITH CHECK enforces it independently regardless. */
@Serializable
data class NewVehicleDto(
    @SerialName("carrier_id") val carrierId: String,
    @SerialName("vehicle_type") val vehicleType: String,
    @SerialName("plate_no") val plateNo: String?,
    @SerialName("make_model") val makeModel: String?,
    @SerialName("capacity_weight_grams") val capacityWeightGrams: Int,
    @SerialName("capacity_volume_cm3") val capacityVolumeCm3: Int,
    @SerialName("capacity_parcels") val capacityParcels: Int,
)

@Serializable
data class VehicleUpdateDto(
    @SerialName("vehicle_type") val vehicleType: String,
    @SerialName("plate_no") val plateNo: String?,
    @SerialName("make_model") val makeModel: String?,
    @SerialName("capacity_weight_grams") val capacityWeightGrams: Int,
    @SerialName("capacity_volume_cm3") val capacityVolumeCm3: Int,
    @SerialName("capacity_parcels") val capacityParcels: Int,
)

@Serializable
data class VehicleActiveUpdateDto(@SerialName("is_active") val isActive: Boolean)

fun NewVehicle.toDto(carrierId: String) = NewVehicleDto(
    carrierId = carrierId,
    vehicleType = vehicleType.wire,
    plateNo = plateNo,
    makeModel = makeModel,
    capacityWeightGrams = capacityWeightGrams,
    capacityVolumeCm3 = capacityVolumeCm3,
    capacityParcels = capacityParcels,
)

fun NewVehicle.toUpdateDto() = VehicleUpdateDto(
    vehicleType = vehicleType.wire,
    plateNo = plateNo,
    makeModel = makeModel,
    capacityWeightGrams = capacityWeightGrams,
    capacityVolumeCm3 = capacityVolumeCm3,
    capacityParcels = capacityParcels,
)
