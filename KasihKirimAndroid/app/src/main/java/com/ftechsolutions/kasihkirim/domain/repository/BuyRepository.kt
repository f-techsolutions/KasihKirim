package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.PaymentStatusInfo

/**
 * Jualan Phase B -- buyer side. carts/cart_items already have full RLS +
 * GRANT (0002/0010_client_privileges.sql), so add/remove/update quantity are
 * plain PostgREST calls; only checkout needs a SECURITY DEFINER bridge
 * (0020_jualan_checkout_and_growth.sql's rpc_checkout), same shape as
 * SellerRepository's own RPC calls.
 */
interface BuyRepository {
    /** Active listings across all sellers. Empty query returns everything;
     *  a non-empty one filters server-side via products' own search_vector. */
    suspend fun browseProducts(query: String = ""): AppResult<List<BuyListing>>

    suspend fun getCart(): AppResult<List<CartLine>>

    /** Creates the caller's cart row on first use (carts.user_id is UNIQUE,
     *  one per user); upserts the cart_items row otherwise. */
    suspend fun addToCart(productId: String, quantity: Int): AppResult<Unit>

    suspend fun updateCartQuantity(cartItemId: String, quantity: Int): AppResult<Unit>

    suspend fun removeFromCart(cartItemId: String): AppResult<Unit>

    /** rpc_checkout (0020, method-aware since 0034). p_voucher_code is only
     *  accepted server-side when the cart holds a single seller's items;
     *  paymentMethod defaults to "COD" -- anything else is sandbox-only
     *  (Billplz, P2-A) and unreachable in a project that hasn't deliberately
     *  enabled it (ref.app_config.payment_methods_enabled). */
    suspend fun checkout(
        destAddressId: String,
        voucherCode: String? = null,
        paymentMethod: String = "COD",
    ): AppResult<CheckoutResult>

    /** rpc_claim_voucher (0020) -- issues the caller a redeemable code from
     *  an active campaign, respecting per_user_limit. */
    suspend fun claimVoucher(campaignId: String): AppResult<String>

    /** payment-intent Edge Function (0034): opens (or, if one already exists,
     *  re-fetches) a hosted Billplz payment page for an order already checked
     *  out with a non-COD method. Sandbox only -- see billplz.ts. Returns the
     *  checkout URL to open in a Custom Tab. */
    suspend fun createPaymentIntent(orderId: String): AppResult<String>

    /** rpc_get_payment_status (0034) -- polled while a Billplz tab is open,
     *  since the webhook that actually captures the payment lands server-side
     *  with no push channel back to this client yet. */
    suspend fun getPaymentStatus(orderId: String): AppResult<PaymentStatusInfo>

    /** The caller's own marketplace orders (orders_select's RLS, 0003), every
     *  status, own rows only -- the buyer-side order-tracking list. */
    suspend fun listMyOrders(): AppResult<List<BuyOrder>>

    /** Buyer-initiated dispute filing. rpc_open_dispute (0028/0032) takes a
     *  delivery id, not an order id, so this resolves order -> kirim_requests
     *  -> deliveries first (both steps RLS-visible to the order's own buyer,
     *  kirim_select/deliveries_select, 0003) before calling it. Raises
     *  DELIVERY_NOT_FOUND if the order was never bridged to a delivery yet
     *  (e.g. still PENDING_PAYMENT). */
    suspend fun fileDispute(orderId: String, category: String, description: String): AppResult<Unit>
}
