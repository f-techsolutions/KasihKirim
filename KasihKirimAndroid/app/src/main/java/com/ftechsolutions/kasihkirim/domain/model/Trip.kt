package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors ref.trip_status exactly (0001_schema.sql). */
enum class TripStatus(val wire: String) {
    DRAFT("DRAFT"), ANNOUNCED("ANNOUNCED"), BOARDING("BOARDING"), DEPARTED("DEPARTED"),
    IN_PROGRESS("IN_PROGRESS"), ARRIVED("ARRIVED"), CLOSED("CLOSED"), CANCELLED("CANCELLED");

    companion object {
        fun fromWire(value: String): TripStatus? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * A carrier's own trip. originNodeId/destNodeId are ref.route_nodes(id) --
 * ref is not PostgREST-exposed, so this client cannot resolve them to a name
 * on its own; the UI falls back to whatever Community happens to share that
 * node_id (same limitation Address/Serviceability already live with).
 */
data class Trip(
    val id: String,
    val status: TripStatus,
    val originNodeId: String,
    val destNodeId: String,
    val departAt: String,
    val capacityWeightGrams: Int,
    val capacityVolumeCm3: Int,
    val capacityParcels: Int,
    val reservedWeightGrams: Int,
    val reservedVolumeCm3: Int,
    val reservedParcels: Int,
)

/** Input to rpc_create_trip. depart_window_minutes/handling_capabilities/
 *  accepts_cod/accepts_beli are left at the RPC's own defaults for this
 *  first slice, same as KirimDraft did for volume/handling/payment in Phase 3. */
data class NewTripDraft(
    val vehicleId: String,
    val originNodeId: String,
    val destNodeId: String,
    val departAtIso: String,
)
