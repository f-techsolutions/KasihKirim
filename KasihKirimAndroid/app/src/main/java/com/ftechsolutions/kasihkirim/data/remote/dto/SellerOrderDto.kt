package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.OrderStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.SellerOrder
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderItem
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.orders, own-seller read (orders_select, 0003),
 *  embedding order_items the same way BuyDto.kt's CartItemDto embeds
 *  products -- both FKs are covered by an index (0020), so PostgREST's
 *  embed inference works without a Columns.raw hint on the join itself. */
@Serializable
data class SellerOrderDto(
    val id: String,
    @SerialName("reference_code") val referenceCode: String,
    val status: String,
    @SerialName("goods_subtotal_sen") val goodsSubtotalSen: Long,
    @SerialName("delivery_fee_sen") val deliveryFeeSen: Long,
    @SerialName("discount_sen") val discountSen: Long,
    @SerialName("total_sen") val totalSen: Long,
    @SerialName("created_at") val createdAt: String,
    @SerialName("order_items") val items: List<SellerOrderItemDto> = emptyList(),
) {
    fun toDomain() = SellerOrder(
        id = id,
        referenceCode = referenceCode,
        status = OrderStatus.fromWire(status) ?: OrderStatus.CREATED,
        goodsSubtotalSen = Sen(goodsSubtotalSen),
        deliveryFeeSen = Sen(deliveryFeeSen),
        discountSen = Sen(discountSen),
        totalSen = Sen(totalSen),
        createdAt = createdAt,
        items = items.map { it.toDomain() },
    )
}

@Serializable
data class SellerOrderItemDto(
    @SerialName("title_snapshot") val titleSnapshot: String,
    @SerialName("price_sen") val priceSen: Long,
    val quantity: Int,
    @SerialName("line_total_sen") val lineTotalSen: Long,
) {
    fun toDomain() = SellerOrderItem(
        titleSnapshot = titleSnapshot,
        priceSen = Sen(priceSen),
        quantity = quantity,
        lineTotalSen = Sen(lineTotalSen),
    )
}
