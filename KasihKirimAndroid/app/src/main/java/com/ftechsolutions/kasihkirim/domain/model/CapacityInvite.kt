package com.ftechsolutions.kasihkirim.domain.model

/** public.capacity_invites (Ajak Kirim, 0006_carrier_commerce.sql) visible
 *  to the caller via invites_select's RLS: their own community, a direct
 *  target, or (for a carrier) one they sent. origin/dest node ids come from
 *  the invite's trip, embedded the same way BoardScreen's own nodeNames map
 *  resolves kirim origin/dest. */
data class CapacityInvite(
    val id: String,
    val message: String?,
    val originNodeId: String,
    val destNodeId: String,
    val expiresAt: String,
)
