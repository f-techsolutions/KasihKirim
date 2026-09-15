package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Embedded via the single FK deliveries.kirim_id -> kirim_requests(id),
 *  the same PostgREST foreign-table pattern AddressDto uses for community. */
@Serializable
data class DeliveryKirimRefDto(
    @SerialName("reference_code") val referenceCode: String,
    @SerialName("item_description") val itemDescription: String,
    @SerialName("kirim_type") val kirimType: String,
    @SerialName("requester_id") val requesterId: String,
)

/** Row shape for public.deliveries (0001_schema.sql), the columns this
 *  client reads for a delivery status list. */
@Serializable
data class DeliveryDto(
    val id: String,
    val status: String,
    @SerialName("carrier_id") val carrierId: String,
    @SerialName("cod_amount_sen") val codAmountSen: Long,
    @SerialName("carrier_earning_sen") val carrierEarningSen: Long? = null,
    @SerialName("failure_reason") val failureReason: String? = null,
    @SerialName("matched_at") val matchedAt: String,
    val kirim: DeliveryKirimRefDto,
) {
    fun toDomain() = Delivery(
        id = id,
        status = KirimStatus.fromWire(status) ?: KirimStatus.MATCHED,
        kirimType = KirimType.fromWire(kirim.kirimType) ?: KirimType.HANTAR,
        referenceCode = kirim.referenceCode,
        itemDescription = kirim.itemDescription,
        codAmountSen = Sen(codAmountSen),
        carrierEarningSen = carrierEarningSen?.let(::Sen),
        failureReason = failureReason,
        matchedAt = matchedAt,
        carrierId = carrierId,
        requesterId = kirim.requesterId,
    )
}

/** Row shape for the delivery_id-only projection of public.reviews used to
 *  find which of the caller's own deliveries they've already rated. */
@Serializable
data class ReviewDeliveryIdDto(
    @SerialName("delivery_id") val deliveryId: String,
)
