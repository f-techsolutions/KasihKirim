package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.products, own-seller read
 *  (0016_seller_onboarding.sql / 0017_seller_product_rpcs.sql). No
 *  category_id: see Product.kt's own comment on why this client never
 *  decodes it. */
@Serializable
data class ProductDto(
    val id: String,
    val title: String,
    val description: String? = null,
    val status: String,
    @SerialName("price_sen") val priceSen: Long,
    val unit: String,
    @SerialName("weight_grams") val weightGrams: Int,
    @SerialName("volume_cm3") val volumeCm3: Int,
    @SerialName("handling_flags") val handlingFlags: List<String> = emptyList(),
    @SerialName("min_order_qty") val minOrderQty: Int,
    @SerialName("rejection_reason") val rejectionReason: String? = null,
    @SerialName("product_images") val images: List<ProductImageDto> = emptyList(),
) {
    fun toDomain() = Product(
        id = id,
        title = title,
        description = description,
        status = ProductStatus.fromWire(status) ?: ProductStatus.DRAFT,
        priceSen = Sen(priceSen),
        unit = unit,
        weightGrams = weightGrams,
        volumeCm3 = volumeCm3,
        handlingFlags = handlingFlags.mapNotNull { HandlingFlag.fromWire(it) },
        minOrderQty = minOrderQty,
        rejectionReason = rejectionReason,
        images = images.map { it.toDomain() }.sortedBy { it.sortOrder },
    )
}

@Serializable
data class ProductImageDto(
    val id: String,
    @SerialName("storage_path") val storagePath: String,
    @SerialName("sort_order") val sortOrder: Int,
) {
    fun toDomain() = ProductImage(id = id, storagePath = storagePath, sortOrder = sortOrder)
}

/** Insert body for public.product_images -- direct Postgrest write, RLS
 *  (product_images_write, 0016) scopes it to the owning seller's own
 *  product. */
@Serializable
data class NewProductImageDto(
    @SerialName("product_id") val productId: String,
    @SerialName("storage_path") val storagePath: String,
    @SerialName("sort_order") val sortOrder: Int,
)

@Serializable
data class ProductStatusUpdateDto(val status: String)
