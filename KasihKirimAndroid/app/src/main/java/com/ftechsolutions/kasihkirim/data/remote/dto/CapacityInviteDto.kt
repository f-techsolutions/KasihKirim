package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.CapacityInvite
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** public.capacity_invites embedding its trip (many-to-one via trip_id ->
 *  trips.id, same embed shape as BuyListingDto's sellers embed) for the
 *  origin/dest node ids -- capacity_invites itself carries none. */
@Serializable
data class CapacityInviteDto(
    val id: String,
    val message: String? = null,
    @SerialName("expires_at") val expiresAt: String,
    val trips: CapacityInviteTripDto,
) {
    fun toDomain() = CapacityInvite(
        id = id,
        message = message,
        originNodeId = trips.originNodeId,
        destNodeId = trips.destNodeId,
        expiresAt = expiresAt,
    )
}

@Serializable
data class CapacityInviteTripDto(
    @SerialName("origin_node_id") val originNodeId: String,
    @SerialName("dest_node_id") val destNodeId: String,
)

@Serializable
data class NewInviteResponseDto(
    @SerialName("invite_id") val inviteId: String,
    @SerialName("user_id") val userId: String,
)
