package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors ref.kirim_status EXACTLY -- all 20 values from 0000_prelude.sql.
 *
 * The simplified DRAFT -> POSTED -> ACCEPTED -> ... example in the brief is
 * NOT the backend: there is no ACCEPTED state. POSTED goes to MATCHED, and a
 * BELI kirim passes through PROCURING before pickup because the carrier buys
 * the goods first.
 *
 * Android NEVER decides a transition. It submits an event to
 * rpc_delivery_transition and renders whatever status comes back; the server
 * validates against ref.delivery_transition_rules.
 */
enum class KirimStatus(val wire: String) {
    DRAFT("DRAFT"),
    POSTED("POSTED"),
    MATCHED("MATCHED"),
    PROCURING("PROCURING"),
    AWAITING_PICKUP("AWAITING_PICKUP"),
    PICKED_UP("PICKED_UP"),
    IN_TRANSIT("IN_TRANSIT"),
    AT_HUB("AT_HUB"),
    OUT_FOR_DELIVERY("OUT_FOR_DELIVERY"),
    DELIVERED("DELIVERED"),
    COMPLETED("COMPLETED"),
    FAILED_PICKUP("FAILED_PICKUP"),
    FAILED_DELIVERY("FAILED_DELIVERY"),
    PROCUREMENT_FAILED("PROCUREMENT_FAILED"),
    RETURNING("RETURNING"),
    RETURNED("RETURNED"),
    CANCELLED("CANCELLED"),
    EXPIRED("EXPIRED"),
    DISPUTED("DISPUTED"),
    REFUNDED("REFUNDED");

    /** Terminal per ARCHITECTURE.md §5.1. Used for UI affordances only. */
    val isTerminal: Boolean
        get() = this in setOf(COMPLETED, CANCELLED, EXPIRED, RETURNED, REFUNDED, PROCUREMENT_FAILED)

    val isFailure: Boolean
        get() = this in setOf(FAILED_PICKUP, FAILED_DELIVERY, PROCUREMENT_FAILED, RETURNED, DISPUTED)

    companion object {
        fun fromWire(value: String): KirimStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** Mirrors ref.kirim_type. BELI is the deck's primary flow: procure and bring. */
enum class KirimType(val wire: String) {
    BELI("BELI"), HANTAR("HANTAR"), PASARAN("PASARAN");
    companion object { fun fromWire(v: String) = entries.firstOrNull { it.wire == v } }
}
