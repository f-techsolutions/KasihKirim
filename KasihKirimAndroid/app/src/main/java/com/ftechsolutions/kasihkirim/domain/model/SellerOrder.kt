package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors ref.order_status (0001_schema.sql) exactly -- uppercase wire
 *  values, a real ref.* enum type unlike ProductStatus's plain column
 *  CHECK. No payment gateway is wired to public.orders yet
 *  (0020_jualan_checkout_and_growth.sql's own comment), so in practice
 *  every order a seller sees today is CREATED; the rest of the enum is
 *  modeled now so the label/tone mapping doesn't need revisiting once a
 *  gateway (or a seller fulfillment RPC) starts moving orders through it. */
enum class OrderStatus(val wire: String) {
    CREATED("CREATED"),
    PENDING_PAYMENT("PENDING_PAYMENT"),
    PAID("PAID"),
    ACCEPTED("ACCEPTED"),
    PREPARING("PREPARING"),
    READY_FOR_PICKUP("READY_FOR_PICKUP"),
    FULFILLED("FULFILLED"),
    SETTLED("SETTLED"),
    PAYMENT_FAILED("PAYMENT_FAILED"),
    EXPIRED("EXPIRED"),
    REJECTED_BY_SELLER("REJECTED_BY_SELLER"),
    CANCELLED("CANCELLED"),
    REFUNDED("REFUNDED"),
    PARTIALLY_REFUNDED("PARTIALLY_REFUNDED");

    val labelMs: String
        get() = when (this) {
            CREATED -> "Pesanan Baharu"
            PENDING_PAYMENT -> "Menunggu Bayaran"
            PAID -> "Telah Dibayar"
            ACCEPTED -> "Diterima"
            PREPARING -> "Sedang Disediakan"
            READY_FOR_PICKUP -> "Sedia Diambil"
            FULFILLED -> "Selesai Dihantar"
            SETTLED -> "Selesai"
            PAYMENT_FAILED -> "Bayaran Gagal"
            EXPIRED -> "Luput"
            REJECTED_BY_SELLER -> "Ditolak Penjual"
            CANCELLED -> "Dibatalkan"
            REFUNDED -> "Dipulangkan"
            PARTIALLY_REFUNDED -> "Sebahagian Dipulangkan"
        }

    companion object {
        fun fromWire(value: String): OrderStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** public.orders, a seller's own read (orders_select's RLS, 0003). Buyer
 *  identity is never shown beyond the address snapshot already taken at
 *  checkout -- there is no buyer-contact column exposed here, same
 *  reasoning as kirim_select's own comment for the carrier board. */
data class SellerOrder(
    val id: String,
    val referenceCode: String,
    val status: OrderStatus,
    val goodsSubtotalSen: Sen,
    val deliveryFeeSen: Sen,
    val discountSen: Sen,
    val commissionSen: Sen,
    val totalSen: Sen,
    val createdAt: String,
    val items: List<SellerOrderItem>,
) {
    /** What actually reaches this seller: the goods price the buyer paid,
     *  net of KasihKirim's commission -- never the delivery fee (the
     *  carrier's own earning) and never the raw total (which also includes
     *  that delivery fee). Matches the same split fn_split_order_capture /
     *  fn_settle_delivery (0024) apply server-side; this is presentation of
     *  the same numbers already on the row, not a new calculation. */
    val netPayableSen: Sen get() = Sen(goodsSubtotalSen.value - commissionSen.value)
}

/** rpc_seller_order_status (0035) -- the delivery/payment side of an order
 *  the seller has no general table read for (kirim_select/deliveries_select
 *  scope to the buyer and the assigned carrier, never the seller). Null
 *  delivery fields mean the order hasn't been matched to a carrier yet --
 *  a normal state, not a missing one. */
data class SellerOrderStatus(
    val orderStatus: OrderStatus,
    val paymentStatus: String?,
    val paymentMethod: String?,
    val deliveryId: String?,
    val deliveryStatus: String?,
    val carrierAssigned: Boolean,
)

/** public.order_items -- title/price are snapshots taken at checkout, not
 *  a live join to products (BR-900, same reasoning CartLine.kt documents
 *  for why cart_items never trusts a live price either). */
data class SellerOrderItem(
    val titleSnapshot: String,
    val priceSen: Sen,
    val quantity: Int,
    val lineTotalSen: Sen,
)
