package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors public.communities (DATABASE.md §5.1), the unit an address is
 * anchored to. Rural addressing here is community + landmark, not street and
 * postcode -- this is the geography picker's source, read-only to clients.
 */
data class Community(
    val id: String,
    val name: String,
    val type: String,
    val district: String,
    val state: String,
    /** ref.route_nodes(id) this community resolves to. Nullable: not every
     *  seeded community has a route node yet. Required to call
     *  rpc_check_serviceability -- ref is not PostgREST-exposed
     *  (supabase/config.toml), so a route node can only be reached this way. */
    val nodeId: String? = null,
)
