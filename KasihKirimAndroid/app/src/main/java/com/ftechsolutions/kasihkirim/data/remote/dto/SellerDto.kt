package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.MuatanJualOnboardingStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.sellers (0016_seller_onboarding.sql,
 *  0007_sabah_geography_compliance.sql for seller_kind/onboarding_status). */
@Serializable
data class SellerDto(
    val id: String,
    @SerialName("business_name") val businessName: String,
    val status: String,
    @SerialName("community_id") val communityId: String,
    @SerialName("ssm_reg_no") val ssmRegNo: String? = null,
    @SerialName("seller_kind") val sellerKind: String = "individual",
    @SerialName("onboarding_status") val onboardingStatus: String = "PENDING",
) {
    fun toDomain() = Seller(
        id = id,
        businessName = businessName,
        status = SellerStatus.fromWire(status) ?: SellerStatus.NOT_STARTED,
        communityId = communityId,
        ssmRegNo = ssmRegNo,
        sellerKind = sellerKind,
        onboardingStatus = MuatanJualOnboardingStatus.fromWire(onboardingStatus) ?: MuatanJualOnboardingStatus.PENDING,
    )
}
