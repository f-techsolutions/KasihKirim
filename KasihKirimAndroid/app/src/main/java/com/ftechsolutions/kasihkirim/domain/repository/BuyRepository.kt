package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.BuyListing

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

    /** rpc_checkout (0020). p_voucher_code is only accepted server-side when
     *  the cart holds a single seller's items. */
    suspend fun checkout(destAddressId: String, voucherCode: String? = null): AppResult<CheckoutResult>

    /** rpc_claim_voucher (0020) -- issues the caller a redeemable code from
     *  an active campaign, respecting per_user_limit. */
    suspend fun claimVoucher(campaignId: String): AppResult<String>
}
