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

/** rpc_checkout's response, one entry per seller represented in the cart. */
data class CheckoutOrderSummary(
    val orderId: String,
    val referenceCode: String,
    val sellerId: String,
    val goodsSubtotalSen: Sen,
    val discountSen: Sen,
    val totalSen: Sen,
)

data class CheckoutResult(
    val orderGroupId: String,
    val orders: List<CheckoutOrderSummary>,
)
