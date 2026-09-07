package com.ftechsolutions.kasihkirim.domain.model

/**
 * The exact response shape of public.rpc_check_serviceability
 * (0011_geography_identity.sql).
 *
 * Five distinct outcomes, modelled as five distinct states. Collapsing them
 * into a generic "route unavailable" would destroy the whole point of the
 * geography work: a customer in Kota Kinabalu asking about Tawau must be told
 * "not open yet", not "unknown".
 */
sealed interface Serviceability {

    data class Serviceable(
        val originDistrict: String,
        val destDistrict: String,
        val distanceKm: Double,
        val estMinutes: Int,
        val requiresWaterTransport: Boolean,
        val hopCount: Int,
    ) : Serviceability

    /** Known district, not yet open. */
    data class DestinationNotActive(val district: String, val status: String) : Serviceability
    data class OriginNotActive(val district: String, val status: String) : Serviceability

    /** Both districts open, but the curated graph does not connect them. */
    data class NoRoute(val originDistrict: String?, val destDistrict: String?) : Serviceability

    /** Genuinely unmapped input -- and ONLY that. */
    data class GeographyUnknown(val side: String?) : Serviceability
}
