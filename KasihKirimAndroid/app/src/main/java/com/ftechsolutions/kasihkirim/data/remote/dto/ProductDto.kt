package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.Inventory
import com.ftechsolutions.kasihkirim.domain.model.InventoryMovement
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.products, own-seller read
 *  (0016_seller_onboarding.sql / 0017_seller_product_rpcs.sql). No
 *  category_id: see Product.kt's own comment on why this client never
 *  decodes it. `inventory` is a reverse one-to-one embed (inventory.product_id
 *  is both its own primary key and the FK to this row) -- the same PostgREST
 *  embed shape as `sellers` on BuyListingDto, just read from the products
 *  side instead. Nullable because a row could in principle predate
 *  tg_products_inventory_row (0025); toDomain() below never fabricates zeros
 *  in that case, it just carries the null through. */
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
    val inventory: InventoryDto? = null,
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
        inventory = inventory?.toDomain(),
    )
}

/** public.inventory embedded on a product read. `available` is derived here
 *  the same way the server's own rpc_set_stock/rpc_adjust_stock compute it
 *  (on_hand - reserved) -- a plain read has no server-computed `available`
 *  field to carry across the wire the way those two RPCs' JSONB responses
 *  do, so this is the one place the client does that specific arithmetic,
 *  matching a value the server would give the identical answer for. */
@Serializable
data class InventoryDto(
    @SerialName("on_hand") val onHand: Int,
    val reserved: Int,
    @SerialName("safety_stock") val safetyStock: Int,
) {
    fun toDomain() = Inventory(onHand = onHand, reserved = reserved, safetyStock = safetyStock, available = onHand - reserved)
}

/** public.inventory_movements, own-product read (inventory_moves_own's RLS,
 *  0006) -- a plain Postgrest select, no RPC needed: the table is append-only
 *  (writes revoked from authenticated, 0010) with the only writer being
 *  internal.fn_adjust_inventory. */
@Serializable
data class InventoryMovementDto(
    val id: String,
    val delta: Int,
    val reason: String,
    @SerialName("created_at") val createdAt: String,
) {
    fun toDomain() = InventoryMovement(id = id, delta = delta, reason = reason, createdAt = createdAt)
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

/** Soft-delete body for public.products -- see SellerRepository.archiveProduct's
 *  own doc comment on why this is a direct Postgrest write, not an RPC. */
@Serializable
data class ProductArchiveDto(@SerialName("deleted_at") val deletedAt: String)
