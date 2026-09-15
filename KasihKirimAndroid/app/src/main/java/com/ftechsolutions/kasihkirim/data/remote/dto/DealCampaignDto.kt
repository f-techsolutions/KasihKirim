package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.DealCampaign
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** public.v_deal_campaigns (0048) -- already joined and filtered
 *  server-side, one row per column the view exposes. */
@Serializable
data class DealCampaignDto(
    val id: String,
    val title: String,
    val subtitle: String?,
    @SerialName("image_path") val imagePath: String,
    @SerialName("product_id") val productId: String,
    @SerialName("product_title") val productTitle: String,
    @SerialName("price_sen") val priceSen: Long,
    val unit: String,
) {
    fun toDomain() = DealCampaign(
        id = id,
        title = title,
        subtitle = subtitle,
        imagePath = imagePath,
        productId = productId,
        productTitle = productTitle,
        priceSen = Sen(priceSen),
        unit = unit,
    )
}
