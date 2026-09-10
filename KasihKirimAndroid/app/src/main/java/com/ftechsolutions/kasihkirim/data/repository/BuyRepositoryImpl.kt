package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.BuyListingDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartItemDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartItemExistenceDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartItemQuantityDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartRowDto
import com.ftechsolutions.kasihkirim.data.remote.dto.NewCartItemDto
import com.ftechsolutions.kasihkirim.data.remote.dto.NewCartRowDto
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutOrderSummary
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException

private const val BUY_LISTING_COLUMNS =
    "id,title,price_sen,unit,weight_grams,min_order_qty," +
        "sellers(id,business_name),product_images(id,storage_path,sort_order)"

private const val CART_ITEM_COLUMNS =
    "id,product_id,quantity,products(title,price_sen,unit,seller_id)"

class BuyRepositoryImpl : BuyRepository {

    private val tag = "BuyRepository"

    override suspend fun browseProducts(query: String): AppResult<List<BuyListing>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("products")
            .select(columns = Columns.raw(BUY_LISTING_COLUMNS)) {
                filter {
                    eq("status", "active")
                    exact("deleted_at", null)
                    if (query.isNotBlank()) ilike("title", "%${query.trim()}%")
                }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<BuyListingDto>()
            .map { it.toDomain() }
    }

    override suspend fun getCart(): AppResult<List<CartLine>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("cart_items")
            .select(columns = Columns.raw(CART_ITEM_COLUMNS))
            .decodeList<CartItemDto>()
            .map { it.toDomain() }
    }

    override suspend fun addToCart(productId: String, quantity: Int): AppResult<Unit> = runCatchingResult {
        val cartId = ensureCartId()
        val existing = SupabaseClientProvider.client.postgrest.from("cart_items")
            .select(columns = Columns.raw("id,quantity")) {
                filter {
                    eq("cart_id", cartId)
                    eq("product_id", productId)
                }
            }
            .decodeList<CartItemExistenceDto>()
            .firstOrNull()

        if (existing != null) {
            SupabaseClientProvider.client.postgrest.from("cart_items")
                .update(CartItemQuantityDto(existing.quantity + quantity)) {
                    filter { eq("id", existing.id) }
                }
        } else {
            SupabaseClientProvider.client.postgrest.from("cart_items")
                .insert(NewCartItemDto(cartId = cartId, productId = productId, quantity = quantity))
        }
        Unit
    }

    override suspend fun updateCartQuantity(cartItemId: String, quantity: Int): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("cart_items")
            .update(CartItemQuantityDto(quantity)) { filter { eq("id", cartItemId) } }
        Unit
    }

    override suspend fun removeFromCart(cartItemId: String): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("cart_items")
            .delete { filter { eq("id", cartItemId) } }
        Unit
    }

    override suspend fun checkout(destAddressId: String, voucherCode: String?): AppResult<CheckoutResult> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_checkout",
                buildJsonObject {
                    put("p_dest_address_id", destAddressId)
                    put("p_voucher_code", voucherCode)
                },
            )
            .decodeAs<JsonObject>()
        CheckoutResult(
            orderGroupId = json.getValue("order_group_id").jsonPrimitive.content,
            orders = json.getValue("orders").jsonArray.map { el ->
                val o = el.jsonObject
                CheckoutOrderSummary(
                    orderId = o.getValue("order_id").jsonPrimitive.content,
                    referenceCode = o.getValue("reference_code").jsonPrimitive.content,
                    sellerId = o.getValue("seller_id").jsonPrimitive.content,
                    goodsSubtotalSen = Sen(o.getValue("goods_subtotal_sen").jsonPrimitive.content.toLong()),
                    discountSen = Sen(o.getValue("discount_sen").jsonPrimitive.content.toLong()),
                    totalSen = Sen(o.getValue("total_sen").jsonPrimitive.content.toLong()),
                )
            },
        )
    }

    override suspend fun claimVoucher(campaignId: String): AppResult<String> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc("rpc_claim_voucher", buildJsonObject { put("p_campaign_id", campaignId) })
            .decodeAs<JsonObject>()
        json.getValue("code").jsonPrimitive.content
    }

    private suspend fun ensureCartId(): String {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        val existing = SupabaseClientProvider.client.postgrest.from("carts")
            .select { filter { eq("user_id", userId) } }
            .decodeList<CartRowDto>()
            .firstOrNull()
        if (existing != null) return existing.id
        return SupabaseClientProvider.client.postgrest.from("carts")
            .insert(NewCartRowDto(userId = userId)) { select() }
            .decodeSingle<CartRowDto>()
            .id
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "buy call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toBuyAppError())
        }
}

private fun Throwable.toBuyAppError(): AppError = when {
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    message?.contains("CART_EMPTY", true) == true -> AppError.Server("CART_EMPTY")
    message?.contains("ADDRESS_NOT_FOUND", true) == true -> AppError.Server("ADDRESS_NOT_FOUND")
    message?.contains("PRODUCT_NOT_AVAILABLE", true) == true -> AppError.Server("PRODUCT_NOT_AVAILABLE")
    message?.contains("INSUFFICIENT_STOCK", true) == true -> AppError.Server("INSUFFICIENT_STOCK")
    message?.contains("VOUCHER_REQUIRES_SINGLE_SELLER", true) == true -> AppError.Server("VOUCHER_REQUIRES_SINGLE_SELLER")
    message?.contains("VOUCHER_NOT_FOUND", true) == true -> AppError.Server("VOUCHER_NOT_FOUND")
    message?.contains("VOUCHER_ALREADY_USED", true) == true -> AppError.Server("VOUCHER_ALREADY_USED")
    message?.contains("VOUCHER_EXPIRED", true) == true -> AppError.Server("VOUCHER_EXPIRED")
    message?.contains("VOUCHER_MIN_ORDER", true) == true -> AppError.Server("VOUCHER_MIN_ORDER")
    message?.contains("VOUCHER_LIMIT_REACHED", true) == true -> AppError.Server("VOUCHER_LIMIT_REACHED")
    message?.contains("CAMPAIGN_NOT_ACTIVE", true) == true -> AppError.Server("CAMPAIGN_NOT_ACTIVE")
    message?.contains("CAMPAIGN_BUDGET_EXHAUSTED", true) == true -> AppError.Server("CAMPAIGN_BUDGET_EXHAUSTED")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
