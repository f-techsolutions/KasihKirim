package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.CarrierProfile
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.carriers (0001_schema.sql), the columns this client
 *  reads for a carrier's own onboarding status -- mirrors SellerDto. */
@Serializable
data class CarrierProfileDto(
    val id: String,
    val status: String,
    @SerialName("home_community_id") val homeCommunityId: String? = null,
) {
    fun toDomain() = CarrierProfile(
        id = id,
        status = SellerStatus.fromWire(status) ?: SellerStatus.NOT_STARTED,
        homeCommunityId = homeCommunityId,
    )
}
