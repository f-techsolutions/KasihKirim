package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors the client-relevant columns of public.vehicles (0001_schema.sql).
 * photo_paths/insurance_expiry/road_tax_expiry/is_verified are admin/Phase-6
 * concerns, not editable here.
 */
data class Vehicle(
    val id: String,
    val vehicleType: VehicleType,
    val plateNo: String?,
    val makeModel: String?,
    val capacityWeightGrams: Int,
    val capacityVolumeCm3: Int,
    val capacityParcels: Int,
    val isActive: Boolean,
)

/** A draft the carrier is composing. Not yet assigned an id by the server. */
data class NewVehicle(
    val vehicleType: VehicleType,
    val plateNo: String?,
    val makeModel: String?,
    val capacityWeightGrams: Int,
    val capacityVolumeCm3: Int,
    val capacityParcels: Int,
)
