package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.DeliveryStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.OrderStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** public.products browsed across sellers, embedding the owning seller
 *  (many-to-one via seller_id -> sellers.id, so PostgREST returns a single
 *  object, not an array -- same shape as ProductDto's own product_images
 *  embed, just the other multiplicity) and its first product_images row. */
@Serializable
data class BuyListingDto(
    val id: String,
    val title: String,
    @SerialName("price_sen") val priceSen: Long,
    val unit: String,
    @SerialName("weight_grams") val weightGrams: Int,
    @SerialName("min_order_qty") val minOrderQty: Int,
    val sellers: BuyListingSellerDto,
    @SerialName("product_images") val images: List<ProductImageDto> = emptyList(),
) {
    fun toDomain() = BuyListing(
        id = id,
        title = title,
        priceSen = Sen(priceSen),
        unit = unit,
        weightGrams = weightGrams,
        minOrderQty = minOrderQty,
        sellerId = sellers.id,
        sellerName = sellers.businessName,
        imagePath = images.minByOrNull { it.sortOrder }?.storagePath,
    )
}

@Serializable
data class BuyListingSellerDto(
    val id: String,
    @SerialName("business_name") val businessName: String,
)

/** public.cart_items embedding the live product row -- the cart itself
 *  holds no price (BR-900); this is display-only, never sent back. */
@Serializable
data class CartItemDto(
    val id: String,
    @SerialName("product_id") val productId: String,
    val quantity: Int,
    val products: CartItemProductDto,
) {
    fun toDomain() = CartLine(
        cartItemId = id,
        productId = productId,
        title = products.title,
        priceSen = Sen(products.priceSen),
        unit = products.unit,
        sellerId = products.sellerId,
        quantity = quantity,
    )
}

/** id/quantity only, no products embed -- for the "does this product
 *  already have a cart_items row" existence check in
 *  BuyRepositoryImpl.addToCart, which has no use for the product's own
 *  columns and (unlike CartItemDto) must not require an embed the query
 *  doesn't request. */
@Serializable
data class CartItemExistenceDto(val id: String, val quantity: Int)

@Serializable
data class CartItemProductDto(
    val title: String,
    @SerialName("price_sen") val priceSen: Long,
    val unit: String,
    @SerialName("seller_id") val sellerId: String,
)

@Serializable
data class NewCartRowDto(@SerialName("user_id") val userId: String)

@Serializable
data class CartRowDto(val id: String)

@Serializable
data class NewCartItemDto(
    @SerialName("cart_id") val cartId: String,
    @SerialName("product_id") val productId: String,
    val quantity: Int,
)

@Serializable
data class CartItemQuantityDto(val quantity: Int)

/** public.orders, the buyer's own read (orders_select's RLS, 0003) -- no
 *  embed, unlike SellerOrderDto: order tracking here only needs the header
 *  row, not the line items. */
@Serializable
data class BuyOrderDto(
    val id: String,
    @SerialName("reference_code") val referenceCode: String,
    val status: String,
    @SerialName("seller_id") val sellerId: String,
    @SerialName("goods_subtotal_sen") val goodsSubtotalSen: Long,
    @SerialName("delivery_fee_sen") val deliveryFeeSen: Long,
    @SerialName("total_sen") val totalSen: Long,
    @SerialName("payment_method") val paymentMethod: String?,
    @SerialName("created_at") val createdAt: String,
    @SerialName("order_items") val items: List<SellerOrderItemDto> = emptyList(),
) {
    fun toDomain() = BuyOrder(
        id = id,
        referenceCode = referenceCode,
        status = OrderStatus.fromWire(status) ?: OrderStatus.CREATED,
        sellerId = sellerId,
        goodsSubtotalSen = Sen(goodsSubtotalSen),
        deliveryFeeSen = Sen(deliveryFeeSen),
        totalSen = Sen(totalSen),
        paymentMethod = paymentMethod,
        createdAt = createdAt,
        items = items.map { it.toDomain() },
    )
}

/** id-only projections for the order -> kirim_requests -> deliveries walk
 *  BuyRepositoryImpl.fileDispute/getDeliveryStatus need to turn an order id
 *  into the delivery id rpc_open_dispute takes, and into the delivery
 *  progress a buyer can already read directly (kirim_select/deliveries_select
 *  both grant the requester_id=auth.uid() a plain read -- no RPC needed). */
@Serializable
data class KirimIdDto(val id: String, val status: String? = null)

@Serializable
data class DeliveryIdDto(val id: String)

/** deliveries.status/carrier_id, own-requester read (deliveries_select, 0003/0009).
 *  status wins over the kirim's own once a delivery exists -- see
 *  BuyRepositoryImpl.getDeliveryStatus's own comment. */
@Serializable
data class DeliveryStatusRowDto(val status: String, @SerialName("carrier_id") val carrierId: String?) {
    fun toDomain() = DeliveryStatusInfo(
        kirimStatus = KirimStatus.fromWire(status) ?: KirimStatus.DRAFT,
        carrierAssigned = carrierId != null,
    )
}
