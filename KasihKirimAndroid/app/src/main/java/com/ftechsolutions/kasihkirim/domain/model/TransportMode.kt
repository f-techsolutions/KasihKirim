package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors ref.vehicle_type (0000_prelude.sql).
 *
 * BOAT is a PEER of CAR, not a Paitan special case. Nothing in this file --
 * and nothing anywhere in the client -- may encode "Paitan means boat". That
 * requirement emerges from ref.route_edges.min_vehicle_type and the
 * serviceability response, both server-side.
 */
enum class TransportMode(val wire: String) {
    MOTORCYCLE("MOTORCYCLE"),
    CAR("CAR"),
    PICKUP("PICKUP"),
    FOURWD("FOURWD"),
    VAN("VAN"),
    LORRY("LORRY"),
    BOAT("BOAT");

    companion object {
        fun fromWire(value: String): TransportMode? = entries.firstOrNull { it.wire == value }
    }
}
