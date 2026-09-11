package com.ftechsolutions.kasihkirim.domain.model

/** public.products joined to its seller and first image, for browsing --
 *  distinct from Product.kt's own model, which is a seller's own listing
 *  (SellerRepository) and never carries seller identity since a seller only
 *  ever lists their own rows. products_select (0003) already scopes this to
 *  status='active' rows for anyone other than the owner/admin. */
data class BuyListing(
    val id: String,
    val title: String,
    val priceSen: Sen,
    val unit: String,
    val weightGrams: Int,
    val minOrderQty: Int,
    val sellerId: String,
    val sellerName: String,
    val imagePath: String?,
)

/** public.cart_items joined to the live product row -- price is never
 *  trusted from here, only resolved server-side at checkout
 *  (rpc_checkout's own comment on cart_items holding no prices, BR-900). */
data class CartLine(
    val cartItemId: String,
    val productId: String,
    val title: String,
    val priceSen: Sen,
    val unit: String,
    val sellerId: String,
    val quantity: Int,
) {
    val lineTotalSen: Sen get() = Sen(priceSen.value * quantity)
}

/** rpc_checkout's response, one entry per seller represented in the cart.
 *  paymentMethod/paymentStatus are the payment intent rpc_checkout already
 *  opens for the order (0034_marketplace_prepaid_billplz.sql): "COD" needs
 *  nothing further, anything else still needs a bill created via
 *  BuyRepository.createPaymentIntent before it can be paid.
 *
 *  deliveryFeeSen was previously dropped even though rpc_checkout's own
 *  response already carries it (found in review) -- totalSen =
 *  goodsSubtotalSen + deliveryFeeSen - discountSen silently absorbed it with
 *  no way for the buyer to see why the total was higher than their cart. */
data class CheckoutOrderSummary(
    val orderId: String,
    val referenceCode: String,
    val sellerId: String,
    val goodsSubtotalSen: Sen,
    val deliveryFeeSen: Sen,
    val discountSen: Sen,
    val totalSen: Sen,
    val paymentId: String,
    val paymentStatus: String,
    val paymentMethod: String,
)

data class CheckoutResult(
    val orderGroupId: String,
    val orders: List<CheckoutOrderSummary>,
)

/** rpc_get_payment_status (0034) -- lets the buyer poll a prepaid order's
 *  payment without re-deriving the bill. checkoutUrl is null until a bill
 *  has actually been created (createPaymentIntent), and always null for COD. */
data class PaymentStatusInfo(
    val paymentId: String,
    val status: String,
    val method: String,
    val amountSen: Sen,
    val checkoutUrl: String?,
    val orderStatus: String,
)

/** public.orders, the buyer's own read (orders_select's RLS, 0003) -- the
 *  marketplace order-tracking list. Shares OrderStatus with SellerOrder.kt:
 *  the same order, seen from the other side of the sale.
 *
 *  goodsSubtotalSen/deliveryFeeSen/items were previously missing (found in
 *  review): the buyer's own order history showed a reference code, a status
 *  badge and a bare total, with no way to see what was actually bought or
 *  how the total split between goods and delivery -- order_items_select
 *  already grants the buyer this same read (0003), so this is server truth,
 *  not a client computation. items reuses SellerOrderItem (SellerOrder.kt):
 *  the same public.order_items row, read from the other side of the sale. */
data class BuyOrder(
    val id: String,
    val referenceCode: String,
    val status: OrderStatus,
    val sellerId: String,
    val goodsSubtotalSen: Sen,
    val deliveryFeeSen: Sen,
    val totalSen: Sen,
    val paymentMethod: String?,
    val createdAt: String,
    val items: List<SellerOrderItem> = emptyList(),
)

/** rpc_seller_order_status's carrier-side fields have no buyer analogue --
 *  kirim_select/deliveries_select already grant the buyer (as the kirim's
 *  own requester_id) a direct read on both tables, so unlike the seller
 *  side (0035_seller_dashboard_and_order_visibility.sql) no new RPC is
 *  needed here, just a plain, RLS-scoped read (BuyRepository.getDeliveryStatus).
 *  Null kirimStatus/carrierAssigned has no meaning -- a null
 *  DeliveryStatusInfo (not this type) is what "not bridged to a delivery job
 *  yet" looks like (e.g. a prepaid order still awaiting payment). */
data class DeliveryStatusInfo(
    val kirimStatus: KirimStatus,
    val carrierAssigned: Boolean,
)

/** The fixed category set public.rpc_open_dispute (0028/0032) accepts --
 *  anything else it refuses outright with INVALID_CATEGORY. */
enum class DisputeCategory(val wire: String, val labelMs: String) {
    NON_DELIVERY("non_delivery", "Tidak Dihantar"),
    DAMAGED("damaged", "Rosak"),
    WRONG_ITEM("wrong_item", "Barang Salah"),
    NOT_AS_DESCRIBED("not_as_described", "Tidak Seperti Diterangkan"),
    PAYMENT("payment", "Isu Bayaran"),
    OVERCHARGE("overcharge", "Caj Berlebihan"),
    CONDUCT("conduct", "Tingkah Laku Tidak Wajar"),
    OTHER("other", "Lain-lain"),
}
