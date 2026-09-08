package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors ref.vehicle_type exactly (0001_schema.sql). BOAT is a peer, not a
 *  special case -- Sabah's water corridors (e.g. Paitan) depend on it. */
enum class VehicleType(val wire: String, val nameMs: String) {
    MOTORCYCLE("MOTORCYCLE", "Motosikal"),
    CAR("CAR", "Kereta"),
    PICKUP("PICKUP", "Pickup"),
    FOURWD("FOURWD", "4WD"),
    VAN("VAN", "Van"),
    LORRY("LORRY", "Lori"),
    BOAT("BOAT", "Bot");

    companion object {
        fun fromWire(value: String): VehicleType? = entries.firstOrNull { it.wire == value }
    }
}
