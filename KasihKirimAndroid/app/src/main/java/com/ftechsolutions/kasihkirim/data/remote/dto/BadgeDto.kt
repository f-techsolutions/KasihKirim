package com.ftechsolutions.kasihkirim.data.remote.dto

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class UserBadgeDto(
    @SerialName("badge_id") val badgeId: String,
    @SerialName("awarded_at") val awardedAt: String,
)

/** public.v_badge_definitions (0021_badge_definitions_view.sql). */
@Serializable
data class BadgeDefinitionDto(
    val id: String,
    val slug: String,
    @SerialName("name_ms") val nameMs: String,
    val icon: String,
)
