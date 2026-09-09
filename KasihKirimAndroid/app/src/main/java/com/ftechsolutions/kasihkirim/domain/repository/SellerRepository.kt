package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller

/**
 * Jualan (Sales) Phase A -- seller onboarding and product catalog only.
 * Checkout/orders/payout are a separate, later phase (see
 * docs/CARRIER_DEVICE_VALIDATION.md's "Jualan scope" decision): the
 * public.orders/order_items/inventory tables exist but have no write RPCs
 * yet, so nothing here touches them.
 */
interface SellerRepository {
    /** null means the caller has never applied. Reads the sellers table
     *  directly (own row, sellers_select's RLS), not the JWT's seller_id
     *  claim -- that claim only exists once APPROVED (custom_access_token_
     *  hook), so it can't tell a NOT_STARTED applicant from a non-applicant. */
    suspend fun getMySellerApplication(): AppResult<Seller?>

    /** rpc_apply_seller (0016). Fails if the caller already has a sellers
     *  row, at any status. */
    suspend fun applySeller(draft: NewSeller): AppResult<Seller>

    suspend fun listMyProducts(sellerId: String): AppResult<List<Product>>

    /** rpc_create_product (0017) -- always creates status='draft' server-side;
     *  there is no way to create anything else. */
    suspend fun createProduct(draft: NewProduct): AppResult<Product>

    /** rpc_update_product (0017) -- editable fields only, never status. */
    suspend fun updateProduct(id: String, draft: NewProduct): AppResult<Product>

    /** Direct Postgrest UPDATE. Only the transitions
     *  internal.tg_protect_product_moderation_columns (0016/0017) actually
     *  permits for a non-admin succeed; anything else is silently reverted
     *  server-side, so this never throws for an authorization reason --
     *  the caller must re-read the product to see whether it actually
     *  changed. */
    suspend fun setProductStatus(id: String, status: ProductStatus): AppResult<Unit>

    /** Uploads to the product-images bucket at {sellerUserId}/{productId}/
     *  {uuid}.jpg (0016's own path convention), then inserts the
     *  product_images row. Refused server-side past 6 images per product
     *  (tg_limit_product_images, 0016). */
    suspend fun uploadProductImage(productId: String, sortOrder: Int, photoBytes: ByteArray): AppResult<ProductImage>

    suspend fun deleteProductImage(imageId: String, storagePath: String): AppResult<Unit>
}
