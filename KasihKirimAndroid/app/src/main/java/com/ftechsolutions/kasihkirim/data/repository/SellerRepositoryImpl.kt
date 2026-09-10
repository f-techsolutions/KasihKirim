package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.NewProductImageDto
import com.ftechsolutions.kasihkirim.data.remote.dto.ProductDto
import com.ftechsolutions.kasihkirim.data.remote.dto.ProductImageDto
import com.ftechsolutions.kasihkirim.data.remote.dto.ProductStatusUpdateDto
import com.ftechsolutions.kasihkirim.data.remote.dto.SellerDto
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.storage.storage
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.util.UUID

private const val PRODUCT_COLUMNS =
    "id,title,description,status,price_sen,unit,weight_grams,volume_cm3,handling_flags," +
        "min_order_qty,rejection_reason,product_images(id,storage_path,sort_order)"

private const val PRODUCT_IMAGES_BUCKET = "product-images"

class SellerRepositoryImpl : SellerRepository {

    private val tag = "SellerRepository"

    override suspend fun getMySellerApplication(): AppResult<Seller?> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        // decodeList().firstOrNull(), not decodeSingleOrNull(): only the
        // decode methods already proven elsewhere in this module
        // (VehicleRepositoryImpl, AddressRepositoryImpl, ...) are used here,
        // rather than assuming a method exists in the pinned supabase-bom
        // 3.5.0 without a working example to confirm it.
        SupabaseClientProvider.client.postgrest.from("sellers")
            .select {
                filter { eq("user_id", userId) }
            }
            .decodeList<SellerDto>()
            .firstOrNull()
            ?.toDomain()
    }

    override suspend fun applySeller(draft: NewSeller): AppResult<Seller> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_apply_seller",
                buildJsonObject {
                    put("p_business_name", draft.businessName)
                    put("p_community_id", draft.communityId)
                    put("p_ssm_reg_no", draft.ssmRegNo)
                },
            )
            .decodeAs<JsonObject>()
        Seller(
            id = json.getValue("seller_id").jsonPrimitive.content,
            businessName = draft.businessName,
            status = SellerStatus.fromWire(json.getValue("status").jsonPrimitive.content) ?: SellerStatus.NOT_STARTED,
            communityId = draft.communityId,
            ssmRegNo = draft.ssmRegNo,
        )
    }

    override suspend fun listMyProducts(sellerId: String): AppResult<List<Product>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("products")
            .select(columns = Columns.raw(PRODUCT_COLUMNS)) {
                filter {
                    eq("seller_id", sellerId)
                    exact("deleted_at", null)
                }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<ProductDto>()
            .map { it.toDomain() }
    }

    override suspend fun createProduct(draft: NewProduct): AppResult<Product> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc("rpc_create_product", draft.toRpcParams())
            .decodeAs<JsonObject>()
        draft.toDomain(id = json.getValue("id").jsonPrimitive.content)
    }

    override suspend fun updateProduct(id: String, draft: NewProduct): AppResult<Product> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc("rpc_update_product", draft.toRpcParams(productId = id))
            .decodeAs<JsonObject>()
        draft.toDomain(id = json.getValue("id").jsonPrimitive.content)
    }

    override suspend fun setProductStatus(id: String, status: ProductStatus): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("products")
            .update(ProductStatusUpdateDto(status.wire)) { filter { eq("id", id) } }
        Unit
    }

    override suspend fun uploadProductImage(
        productId: String,
        sortOrder: Int,
        photoBytes: ByteArray,
    ): AppResult<ProductImage> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        // First path segment must equal the uploader's own auth uid --
        // product_images_bucket_insert_owner (0016) checks exactly that.
        val path = "$userId/$productId/${UUID.randomUUID()}.jpg"
        SupabaseClientProvider.client.storage.from(PRODUCT_IMAGES_BUCKET).upload(path, photoBytes)

        SupabaseClientProvider.client.postgrest.from("product_images")
            .insert(NewProductImageDto(productId = productId, storagePath = path, sortOrder = sortOrder)) {
                select()
            }
            .decodeSingle<ProductImageDto>()
            .toDomain()
    }

    override suspend fun deleteProductImage(imageId: String, storagePath: String): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.storage.from(PRODUCT_IMAGES_BUCKET).delete(listOf(storagePath))
        SupabaseClientProvider.client.postgrest.from("product_images")
            .delete { filter { eq("id", imageId) } }
        Unit
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "seller call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toSellerAppError())
        }
}

private fun NewProduct.toRpcParams(productId: String? = null) = buildJsonObject {
    if (productId != null) put("p_product_id", productId)
    put("p_title", title)
    put("p_category_slug", category.slug)
    put("p_price_sen", priceSen)
    put("p_weight_grams", weightGrams)
    put("p_description", description)
    put("p_unit", unit)
    put("p_volume_cm3", volumeCm3)
    put("p_handling_flags", buildJsonArray {
        handlingFlags.forEach { add(JsonPrimitive(it.wire)) }
    })
    put("p_min_order_qty", minOrderQty)
}

private fun NewProduct.toDomain(id: String) = Product(
    id = id,
    title = title,
    description = description,
    status = ProductStatus.DRAFT,
    priceSen = Sen(priceSen),
    unit = unit,
    weightGrams = weightGrams,
    volumeCm3 = volumeCm3,
    handlingFlags = handlingFlags,
    minOrderQty = minOrderQty,
    rejectionReason = null,
    images = emptyList(),
)

private fun Throwable.toSellerAppError(): AppError = when {
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    message?.contains("SELLER_APPLICATION_EXISTS", true) == true -> AppError.Server("SELLER_APPLICATION_EXISTS")
    message?.contains("COMMUNITY_NOT_FOUND", true) == true -> AppError.Server("COMMUNITY_NOT_FOUND")
    message?.contains("BUSINESS_NAME_TOO_SHORT", true) == true -> AppError.Server("BUSINESS_NAME_TOO_SHORT")
    message?.contains("NOT_A_SELLER", true) == true -> AppError.NotAuthorized
    message?.contains("CATEGORY_NOT_FOUND", true) == true -> AppError.Server("CATEGORY_NOT_FOUND")
    message?.contains("PRODUCT_NOT_FOUND", true) == true -> AppError.Server("PRODUCT_NOT_FOUND")
    message?.contains("PRODUCT_IMAGE_LIMIT", true) == true -> AppError.Server("PRODUCT_IMAGE_LIMIT")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
