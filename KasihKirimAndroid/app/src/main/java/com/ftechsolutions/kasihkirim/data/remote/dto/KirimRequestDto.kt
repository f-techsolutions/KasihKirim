package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.kirim_requests (0001_schema.sql), the columns this
 *  client reads for board/order listings. */
@Serializable
data class KirimRequestDto(
    val id: String,
    @SerialName("reference_code") val referenceCode: String,
    @SerialName("kirim_type") val kirimType: String,
    val status: String,
    @SerialName("item_description") val itemDescription: String,
    @SerialName("est_weight_grams") val estWeightGrams: Int,
    @SerialName("origin_node_id") val originNodeId: String,
    @SerialName("dest_node_id") val destNodeId: String,
    @SerialName("budget_cap_sen") val budgetCapSen: Long? = null,
    @SerialName("delivery_fee_sen") val deliveryFeeSen: Long? = null,
    @SerialName("commission_sen") val commissionSen: Long? = null,
    @SerialName("created_at") val createdAt: String,
) {
    fun toDomain() = KirimSummary(
        id = id,
        referenceCode = referenceCode,
        kirimType = KirimType.fromWire(kirimType) ?: KirimType.HANTAR,
        status = KirimStatus.fromWire(status) ?: KirimStatus.DRAFT,
        itemDescription = itemDescription,
        estWeightGrams = estWeightGrams,
        originNodeId = originNodeId,
        destNodeId = destNodeId,
        budgetCapSen = budgetCapSen?.let(::Sen),
        deliveryFeeSen = deliveryFeeSen?.let(::Sen),
        commissionSen = commissionSen?.let(::Sen),
        createdAt = createdAt,
    )
}
