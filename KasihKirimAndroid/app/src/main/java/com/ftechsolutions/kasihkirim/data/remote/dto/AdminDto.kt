package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
import com.ftechsolutions.kasihkirim.domain.model.ProductReview
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.SellerApplication
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** public.sellers read as a reviewer -- review_note added in 0023. */
@Serializable
data class SellerApplicationDto(
    val id: String,
    @SerialName("business_name") val businessName: String,
    @SerialName("ssm_reg_no") val ssmRegNo: String? = null,
    val status: String,
    @SerialName("review_note") val reviewNote: String? = null,
    @SerialName("created_at") val createdAt: String,
) {
    fun toDomain() = SellerApplication(
        id = id,
        businessName = businessName,
        ssmRegNo = ssmRegNo,
        status = SellerStatus.fromWire(status) ?: SellerStatus.NOT_STARTED,
        reviewNote = reviewNote,
        createdAt = createdAt,
    )
}

/** public.products with its seller embedded, read as a reviewer. */
@Serializable
data class ProductReviewDto(
    val id: String,
    val title: String,
    val description: String? = null,
    val status: String,
    @SerialName("price_sen") val priceSen: Long,
    val unit: String,
    @SerialName("created_at") val createdAt: String,
    val sellers: ProductReviewSellerDto? = null,
) {
    fun toDomain() = ProductReview(
        id = id,
        title = title,
        description = description,
        status = ProductStatus.fromWire(status) ?: ProductStatus.DRAFT,
        priceSen = Sen(priceSen),
        unit = unit,
        sellerName = sellers?.businessName.orEmpty(),
        createdAt = createdAt,
    )
}

@Serializable
data class ProductReviewSellerDto(
    @SerialName("business_name") val businessName: String,
)

@Serializable
data class DisputeDto(
    val id: String,
    val category: String,
    val description: String,
    val status: String,
    @SerialName("refund_sen") val refundSen: Long,
    @SerialName("holds_escrow") val holdsEscrow: Boolean,
    @SerialName("resolution_note") val resolutionNote: String? = null,
    @SerialName("sla_due_at") val slaDueAt: String,
    @SerialName("created_at") val createdAt: String,
) {
    fun toDomain() = Dispute(
        id = id,
        category = category,
        description = description,
        status = DisputeStatus.fromWire(status) ?: DisputeStatus.OPEN,
        refundSen = Sen(refundSen),
        holdsEscrow = holdsEscrow,
        resolutionNote = resolutionNote,
        slaDueAt = slaDueAt,
        createdAt = createdAt,
    )
}
