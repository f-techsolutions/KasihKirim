package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Inventory
import com.ftechsolutions.kasihkirim.domain.model.InventoryMovement
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerDashboard
import com.ftechsolutions.kasihkirim.domain.model.SellerOrder
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderStatus

/**
 * Jualan (Sales) Phase A -- seller onboarding and product catalog.
 * listMyOrders (Phase B, 0020_jualan_checkout_and_growth.sql) is read-only:
 * a buyer's rpc_checkout is the only writer of public.orders/order_items,
 * and no seller fulfillment RPC exists yet -- there is nothing for a seller
 * to change on an order here, only to see it. getOrderStatus/openOrderDispute
 * (P2, 0035) are the two things a seller CAN do/see beyond that: read the
 * delivery/payment side of their own order, and raise a dispute on it the
 * same way rpc_delivery_transition already lets a seller do (0030) --
 * neither is a new fulfillment capability, both existed server-side already.
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

    /** rpc_accept_muatan_jual_terms (0047) -- the seller's own acceptance
     *  step, only valid once an admin has moved onboardingStatus to
     *  APPROVED (rpc_admin_review_muatan_jual_seller, console-side).
     *  Moves APPROVED -> ACTIVE, the state rpc_create_lot requires. */
    suspend fun acceptMuatanJualTerms(): AppResult<Unit>

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

    /** Orders placed against this seller's products, newest first. */
    suspend fun listMyOrders(sellerId: String): AppResult<List<SellerOrder>>

    /** rpc_seller_dashboard (0035) -- product/listing/order/low-stock counts,
     *  scoped to the caller's own seller row server-side. */
    suspend fun getDashboard(): AppResult<SellerDashboard>

    /** rpc_set_stock (0025) -- sets on_hand to an absolute figure; refuses to
     *  cut below what's already reserved by live orders. p_safety_stock is
     *  left unchanged when null. */
    suspend fun setStock(productId: String, onHand: Int, safetyStock: Int? = null): AppResult<Inventory>

    /** rpc_adjust_stock (0025) -- a signed delta (a restock, a spoilage
     *  write-off, a correction), recorded as an inventory_movements row
     *  under the given reason label. */
    suspend fun adjustStock(productId: String, delta: Int, reason: String = "seller_adjust"): AppResult<Inventory>

    /** public.inventory_movements, own-product read (inventory_moves_own's
     *  RLS, 0006) -- newest first. */
    suspend fun listStockMovements(productId: String): AppResult<List<InventoryMovement>>

    /** Soft-delete: a direct Postgrest UPDATE of products.deleted_at, the
     *  same class of write setProductStatus already uses for status. Not an
     *  RPC -- no SECURITY DEFINER logic is needed, RLS (products_write) and
     *  ownership already gate it, and the moderation trigger (0016/0017)
     *  never touches this column. Once set, the product drops out of
     *  listMyProducts (its own deleted_at IS NULL filter) permanently --
     *  there is no matching "unarchive". */
    suspend fun archiveProduct(id: String): AppResult<Unit>

    /** rpc_seller_order_status (0035) -- the delivery/payment status of the
     *  seller's own order. kirim_select/deliveries_select never grant a
     *  seller a general read on those two tables; this is a narrow,
     *  ownership-checked substitute, not a policy change. */
    suspend fun getOrderStatus(orderId: String): AppResult<SellerOrderStatus>

    /** rpc_open_seller_dispute (0038) -- a seller-facing counterpart to the
     *  buyer's rpc_open_dispute, authorized the same way rpc_delivery_transition
     *  (0030) already authorizes a seller's bare OPEN_DISPUTE: ownership via
     *  orders.seller_id -> sellers.user_id, not role membership alone. Unlike
     *  the generic transition RPC this used to call, this one takes a real
     *  category and description instead of falling back to 0032's truthful
     *  'other' default. */
    suspend fun openOrderDispute(deliveryId: String, category: String, description: String): AppResult<Unit>
}
