package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors the client-relevant columns of public.addresses (DATABASE.md §4.4).
 *
 * photo_path, voice_note_path, geog and nearest_node_id are deliberately
 * absent: they need a provisioned storage bucket and device geo-capture,
 * neither of which exists yet (Phase 6). Landmark text plus a community pin
 * is enough for a courier to find the place until then.
 */
data class Address(
    val id: String,
    val label: String,
    val recipientName: String,
    val recipientPhone: String,
    val community: Community,
    val landmarkNote: String,
    val isDefault: Boolean,
)

/** A draft the user is composing. Not yet assigned an id by the server. */
data class NewAddress(
    val label: String,
    val recipientName: String,
    val recipientPhone: String,
    val communityId: String,
    val landmarkNote: String,
)
