package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.communities (DATABASE.md §5.1). */
@Serializable
data class CommunityDto(
    val id: String,
    val name: String,
    val type: String,
    val district: String,
    val state: String,
) {
    fun toDomain() = Community(id = id, name = name, type = type, district = district, state = state)
}

/**
 * Row shape for public.addresses (DATABASE.md §4.4), embedding the
 * community via a PostgREST foreign-table select. Only the columns this
 * client actually uses are declared -- photo_path, voice_note_path, geog and
 * nearest_node_id are server/Phase-6 concerns.
 */
@Serializable
data class AddressDto(
    val id: String,
    val label: String,
    @SerialName("recipient_name") val recipientName: String,
    @SerialName("recipient_phone") val recipientPhone: String,
    @SerialName("landmark_note") val landmarkNote: String,
    @SerialName("is_default") val isDefault: Boolean,
    val community: CommunityDto,
) {
    fun toDomain() = Address(
        id = id,
        label = label,
        recipientName = recipientName,
        recipientPhone = recipientPhone,
        community = community.toDomain(),
        landmarkNote = landmarkNote,
        isDefault = isDefault,
    )
}

/** Insert body for public.addresses. user_id is set from the session, never
 *  from client input -- RLS's WITH CHECK enforces it independently. */
@Serializable
data class NewAddressDto(
    @SerialName("user_id") val userId: String,
    val label: String,
    @SerialName("recipient_name") val recipientName: String,
    @SerialName("recipient_phone") val recipientPhone: String,
    @SerialName("community_id") val communityId: String,
    @SerialName("landmark_note") val landmarkNote: String,
)

/** Update body for public.addresses. No user_id here: ownership is
 *  immutable from the client and RLS's "own" policy scopes the row anyway. */
@Serializable
data class AddressUpdateDto(
    val label: String,
    @SerialName("recipient_name") val recipientName: String,
    @SerialName("recipient_phone") val recipientPhone: String,
    @SerialName("community_id") val communityId: String,
    @SerialName("landmark_note") val landmarkNote: String,
)
