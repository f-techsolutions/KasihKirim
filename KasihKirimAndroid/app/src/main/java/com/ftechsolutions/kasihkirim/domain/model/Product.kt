package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors public.products' status CHECK constraint exactly
 *  (0016_seller_onboarding.sql confirmed live) -- lowercase wire values,
 *  unlike every other status enum in this app, because that's the actual
 *  column's own CHECK, not a ref.* enum type. */
enum class ProductStatus(val wire: String) {
    DRAFT("draft"),
    PENDING_REVIEW("pending_review"),
    ACTIVE("active"),
    PAUSED("paused"),
    REJECTED("rejected"),
    DELISTED("delisted");

    val labelMs: String
        get() = when (this) {
            DRAFT -> "Draf"
            PENDING_REVIEW -> "Dalam Semakan"
            ACTIVE -> "Aktif"
            PAUSED -> "Dijeda"
            REJECTED -> "Ditolak"
            DELISTED -> "Ditarik Balik"
        }

    companion object {
        fun fromWire(value: String): ProductStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** public.products -- the seller's own listing.
 *
 * No category field: category_id is a UUID into ref.categories, which is
 * not PostgREST-exposed (supabase/config.toml) -- the exact same
 * limitation MuatanJualListing.kt already documents for
 * carrier_stock_lots.category_id. rpc_create_product/rpc_update_product
 * take a slug and resolve it server-side, so composing a listing never
 * needs the id either -- but reading one back can't show what category it
 * is in, only what was picked at creation time (kept in the create/edit
 * form's own state, not in this model). */
data class Product(
    val id: String,
    val title: String,
    val description: String?,
    val status: ProductStatus,
    val priceSen: Sen,
    val unit: String,
    val weightGrams: Int,
    val volumeCm3: Int,
    val handlingFlags: List<HandlingFlag>,
    val minOrderQty: Int,
    val rejectionReason: String?,
    val images: List<ProductImage> = emptyList(),
    /** null only if the row somehow predates tg_products_inventory_row
     *  (0025) -- every product created since has one from the moment it
     *  exists, on_hand/reserved/safety_stock all starting at 0. */
    val inventory: Inventory? = null,
)

/** public.inventory, the single server-authoritative source for stock
 *  (0025_seller_product_stock.sql). Never computed client-side: `available`
 *  is read straight off rpc_set_stock/rpc_adjust_stock's own response, the
 *  same number the server just used to decide whether the change was legal. */
data class Inventory(
    val onHand: Int,
    val reserved: Int,
    val safetyStock: Int,
    val available: Int,
) {
    val isLowStock: Boolean get() = onHand <= safetyStock
}

/** public.inventory_movements -- an append-only audit row (0025), read-only
 *  from this client; the only writer is internal.fn_adjust_inventory. */
data class InventoryMovement(
    val id: String,
    val delta: Int,
    val reason: String,
    val createdAt: String,
)

data class ProductImage(
    val id: String,
    val storagePath: String,
    val sortOrder: Int,
) {
    /** product-images is a public bucket (0016) -- no signed URL, no auth
     *  header, just the plain object URL. */
    fun publicUrl(supabaseUrl: String): String =
        "$supabaseUrl/storage/v1/object/public/product-images/$storagePath"
}

/** A product listing the seller is composing -- rpc_create_product /
 *  rpc_update_product's params, 1:1. */
data class NewProduct(
    val title: String,
    val description: String?,
    val category: KirimCategory,
    val priceSen: Long,
    val unit: String,
    val weightGrams: Int,
    val volumeCm3: Int,
    val handlingFlags: List<HandlingFlag>,
    val minOrderQty: Int,
)
