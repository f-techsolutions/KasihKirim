package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.BuyListingDto
import com.ftechsolutions.kasihkirim.data.remote.dto.BuyOrderDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartItemDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartItemExistenceDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartItemQuantityDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CartRowDto
import com.ftechsolutions.kasihkirim.data.remote.dto.DeliveryIdDto
import com.ftechsolutions.kasihkirim.data.remote.dto.KirimIdDto
import com.ftechsolutions.kasihkirim.data.remote.dto.NewCartItemDto
import com.ftechsolutions.kasihkirim.data.remote.dto.NewCartRowDto
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutOrderSummary
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.PaymentStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.functions.functions
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.ktor.client.statement.bodyAsText
import io.ktor.http.isSuccess
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException

private const val BUY_LISTING_COLUMNS =
    "id,title,price_sen,unit,weight_grams,min_order_qty," +
        "sellers(id,business_name),product_images(id,storage_path,sort_order)"

private const val CART_ITEM_COLUMNS =
    "id,product_id,quantity,products(title,price_sen,unit,seller_id)"

private const val BUY_ORDER_COLUMNS =
    "id,reference_code,status,seller_id,total_sen,payment_method,created_at"

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

    override suspend fun checkout(
        destAddressId: String,
        voucherCode: String?,
        paymentMethod: String,
    ): AppResult<CheckoutResult> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_checkout",
                buildJsonObject {
                    put("p_dest_address_id", destAddressId)
                    put("p_voucher_code", voucherCode)
                    put("p_payment_method", paymentMethod)
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
                    paymentId = o.getValue("payment_id").jsonPrimitive.content,
                    paymentStatus = o.getValue("payment_status").jsonPrimitive.content,
                    paymentMethod = o.getValue("payment_method").jsonPrimitive.content,
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

    // functions-kt is new to this app with this call (P2-A) -- every other
    // Supabase module here (auth/postgrest/storage) was already in use, so
    // their call shapes were confirmed by the existing code they support.
    // Functions.invoke()'s exact parameter names/overload are written from
    // documented supabase-kt knowledge, not verified against a real build in
    // this environment (no Android SDK here -- see PR description). If this
    // line doesn't compile, the fix is almost certainly just this call's
    // shape, not the surrounding design.
    override suspend fun createPaymentIntent(orderId: String): AppResult<String> = runCatchingResult {
        // The Edge Function's own error shape ({error:{code,...}}, see
        // _shared/http.ts) is surfaced as an exception message so
        // toBuyAppError's string matching below catches it exactly like a
        // Postgres-raised RPC error.
        val response = SupabaseClientProvider.client.functions.invoke(
            function = "payment-intent",
            body = buildJsonObject { put("order_id", orderId) },
        )
        val body = Json.parseToJsonElement(response.bodyAsText()).jsonObject
        if (!response.status.isSuccess()) {
            val code = body["error"]?.jsonObject?.get("code")?.jsonPrimitive?.content
            throw IllegalStateException(code ?: "INTERNAL")
        }
        body.getValue("checkout_url").jsonPrimitive.content
    }

    override suspend fun getPaymentStatus(orderId: String): AppResult<PaymentStatusInfo> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc("rpc_get_payment_status", buildJsonObject { put("p_order", orderId) })
            .decodeAs<JsonObject>()
        PaymentStatusInfo(
            paymentId = json.getValue("payment_id").jsonPrimitive.content,
            status = json.getValue("status").jsonPrimitive.content,
            method = json.getValue("method").jsonPrimitive.content,
            amountSen = Sen(json.getValue("amount_sen").jsonPrimitive.content.toLong()),
            checkoutUrl = json["checkout_url"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content,
            orderStatus = json.getValue("order_status").jsonPrimitive.content,
        )
    }

    override suspend fun listMyOrders(): AppResult<List<BuyOrder>> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        SupabaseClientProvider.client.postgrest.from("orders")
            .select(columns = Columns.raw(BUY_ORDER_COLUMNS)) {
                filter { eq("buyer_id", userId) }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<BuyOrderDto>()
            .map { it.toDomain() }
    }

    override suspend fun fileDispute(orderId: String, category: String, description: String): AppResult<Unit> =
        runCatchingResult {
            val kirimId = SupabaseClientProvider.client.postgrest.from("kirim_requests")
                .select(columns = Columns.raw("id")) { filter { eq("order_id", orderId) } }
                .decodeList<KirimIdDto>()
                .firstOrNull()?.id
                ?: throw IllegalStateException("DELIVERY_NOT_FOUND")
            val deliveryId = SupabaseClientProvider.client.postgrest.from("deliveries")
                .select(columns = Columns.raw("id")) { filter { eq("kirim_id", kirimId) } }
                .decodeList<DeliveryIdDto>()
                .firstOrNull()?.id
                ?: throw IllegalStateException("DELIVERY_NOT_FOUND")

            SupabaseClientProvider.client.postgrest.rpc(
                "rpc_open_dispute",
                buildJsonObject {
                    put("p_delivery", deliveryId)
                    put("p_category", category)
                    put("p_description", description)
                },
            )
            Unit
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
    // 0034 / payment-intent (P2-A).
    message?.contains("ORDER_NOT_FOUND", true) == true -> AppError.Server("ORDER_NOT_FOUND")
    message?.contains("PAYMENT_METHOD_NOT_ENABLED", true) == true -> AppError.Server("PAYMENT_METHOD_NOT_ENABLED")
    message?.contains("PAYMENT_METHOD_UNKNOWN", true) == true -> AppError.Server("PAYMENT_METHOD_UNKNOWN")
    message?.contains("PAYMENT_METHOD_IS_COD", true) == true -> AppError.Server("PAYMENT_METHOD_IS_COD")
    message?.contains("PAYMENT_NOT_PENDING", true) == true -> AppError.Server("PAYMENT_NOT_PENDING")
    message?.contains("PAYMENT_MISSING", true) == true -> AppError.Server("PAYMENT_MISSING")
    message?.contains("BILLPLZ_CREATE_BILL_FAILED", true) == true -> AppError.Server("BILLPLZ_CREATE_BILL_FAILED")
    message?.contains("AUTH_SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    // Dispute filing (0028/0032, via rpc_open_dispute).
    message?.contains("INVALID_CATEGORY", true) == true -> AppError.Server("INVALID_CATEGORY")
    message?.contains("DESCRIPTION_TOO_SHORT", true) == true -> AppError.Server("DESCRIPTION_TOO_SHORT")
    message?.contains("DELIVERY_NOT_FOUND", true) == true -> AppError.Server("DELIVERY_NOT_FOUND")
    message?.contains("DISPUTE_ALREADY_OPEN", true) == true -> AppError.Server("DISPUTE_ALREADY_OPEN")
    message?.contains("STATE_ACTOR_NOT_PERMITTED", true) == true -> AppError.Server("STATE_ACTOR_NOT_PERMITTED")
    message?.contains("STATE_INVALID_TRANSITION", true) == true -> AppError.Server("STATE_INVALID_TRANSITION")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
