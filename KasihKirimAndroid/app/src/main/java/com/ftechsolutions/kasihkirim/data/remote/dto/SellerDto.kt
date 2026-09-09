package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.sellers (0016_seller_onboarding.sql). */
@Serializable
data class SellerDto(
    val id: String,
    @SerialName("business_name") val businessName: String,
    val status: String,
    @SerialName("community_id") val communityId: String,
    @SerialName("ssm_reg_no") val ssmRegNo: String? = null,
) {
    fun toDomain() = Seller(
        id = id,
        businessName = businessName,
        status = SellerStatus.fromWire(status) ?: SellerStatus.NOT_STARTED,
        communityId = communityId,
        ssmRegNo = ssmRegNo,
    )
}
