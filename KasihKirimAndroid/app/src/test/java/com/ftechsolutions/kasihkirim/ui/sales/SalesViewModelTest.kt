package com.ftechsolutions.kasihkirim.ui.sales

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.Inventory
import com.ftechsolutions.kasihkirim.domain.model.InventoryMovement
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerDashboard
import com.ftechsolutions.kasihkirim.domain.model.SellerOrder
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderItem
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderStatus
import com.ftechsolutions.kasihkirim.domain.model.OrderStatus
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val KEPAYAN = Community(id = "c1", name = "Kg Kepayan Baru", type = "kampung", district = "Kota Kinabalu", state = "Sabah", nodeId = "n1")

private val APPROVED_SELLER = Seller(id = "s1", businessName = "Kedai Aisyah", status = SellerStatus.APPROVED, communityId = "c1", ssmRegNo = null)

private val DRAFT_PRODUCT = Product(
    id = "p1", title = "Ikan Bilis", description = null, status = ProductStatus.DRAFT,
    priceSen = Sen(1500), unit = "kg", weightGrams = 500, volumeCm3 = 8000,
    handlingFlags = emptyList(), minOrderQty = 1, rejectionReason = null, images = emptyList(),
)

private class FakeAddressRepository(var communities: List<Community> = listOf(KEPAYAN)) : AddressRepository {
    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()
    override suspend fun searchCommunities(query: String): AppResult<List<Community>> = AppResult.Success(communities)
}

private class FakeSellerRepository(
    var seller: Seller? = null,
    var products: List<Product> = emptyList(),
    var orders: List<SellerOrder> = emptyList(),
    var applyResult: AppResult<Seller>? = null,
    var createProductResult: AppResult<Product>? = null,
    var dashboardResult: AppResult<SellerDashboard>? = null,
    var setStockResult: AppResult<Inventory>? = null,
    var adjustStockResult: AppResult<Inventory>? = null,
    var movements: List<InventoryMovement> = emptyList(),
    var orderStatusResult: AppResult<SellerOrderStatus>? = null,
    var openDisputeResult: AppResult<Unit>? = null,
    var archiveResult: AppResult<Unit>? = null,
) : SellerRepository {
    var setStatusCalls = 0
    var lastStatus: ProductStatus? = null
    var lastSetStockOnHand: Int? = null
    var lastSetStockSafety: Int? = null
    var lastAdjustDelta: Int? = null
    var lastArchivedId: String? = null
    var lastDisputeDeliveryId: String? = null

    override suspend fun getMySellerApplication(): AppResult<Seller?> = AppResult.Success(seller)

    override suspend fun applySeller(draft: NewSeller): AppResult<Seller> =
        applyResult ?: AppResult.Success(Seller(id = "s1", businessName = draft.businessName, status = SellerStatus.NOT_STARTED, communityId = draft.communityId, ssmRegNo = draft.ssmRegNo))

    override suspend fun listMyProducts(sellerId: String): AppResult<List<Product>> = AppResult.Success(products)

    override suspend fun createProduct(draft: NewProduct): AppResult<Product> =
        createProductResult ?: AppResult.Success(
            Product(
                id = "p1", title = draft.title, description = draft.description, status = ProductStatus.DRAFT,
                priceSen = Sen(draft.priceSen), unit = draft.unit, weightGrams = draft.weightGrams,
                volumeCm3 = draft.volumeCm3, handlingFlags = draft.handlingFlags, minOrderQty = draft.minOrderQty,
                rejectionReason = null, images = emptyList(),
            ),
        )

    override suspend fun updateProduct(id: String, draft: NewProduct): AppResult<Product> = throw NotImplementedError()

    override suspend fun setProductStatus(id: String, status: ProductStatus): AppResult<Unit> {
        setStatusCalls++
        lastStatus = status
        return AppResult.Success(Unit)
    }

    override suspend fun uploadProductImage(productId: String, sortOrder: Int, photoBytes: ByteArray): AppResult<ProductImage> =
        AppResult.Success(ProductImage(id = "img1", storagePath = "u/$productId/img1.jpg", sortOrder = sortOrder))

    override suspend fun deleteProductImage(imageId: String, storagePath: String): AppResult<Unit> = AppResult.Success(Unit)

    override suspend fun listMyOrders(sellerId: String): AppResult<List<SellerOrder>> = AppResult.Success(orders)

    override suspend fun getDashboard(): AppResult<SellerDashboard> =
        dashboardResult ?: AppResult.Success(SellerDashboard(0, 0, 0, 0, 0))

    override suspend fun setStock(productId: String, onHand: Int, safetyStock: Int?): AppResult<Inventory> {
        lastSetStockOnHand = onHand
        lastSetStockSafety = safetyStock
        return setStockResult ?: AppResult.Success(Inventory(onHand = onHand, reserved = 0, safetyStock = safetyStock ?: 0, available = onHand))
    }

    override suspend fun adjustStock(productId: String, delta: Int, reason: String): AppResult<Inventory> {
        lastAdjustDelta = delta
        return adjustStockResult ?: AppResult.Success(Inventory(onHand = delta, reserved = 0, safetyStock = 0, available = delta))
    }

    override suspend fun listStockMovements(productId: String): AppResult<List<InventoryMovement>> = AppResult.Success(movements)

    override suspend fun archiveProduct(id: String): AppResult<Unit> {
        lastArchivedId = id
        return archiveResult ?: AppResult.Success(Unit)
    }

    override suspend fun getOrderStatus(orderId: String): AppResult<SellerOrderStatus> =
        orderStatusResult ?: AppResult.Success(
            SellerOrderStatus(
                orderStatus = OrderStatus.PENDING_PAYMENT, paymentStatus = "COD_PENDING", paymentMethod = "COD",
                deliveryId = null, deliveryStatus = null, carrierAssigned = false,
            ),
        )

    override suspend fun openOrderDispute(deliveryId: String): AppResult<Unit> {
        lastDisputeDeliveryId = deliveryId
        return openDisputeResult ?: AppResult.Success(Unit)
    }
}

private class FakeEarningsRepository(var result: AppResult<Earnings> = AppResult.Success(Earnings(Sen.ZERO, Sen.ZERO, null, null))) :
    EarningsRepository {
    override suspend fun myEarnings(): AppResult<Earnings> = result
}

@OptIn(ExperimentalCoroutinesApi::class)
class SalesViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `with no application, seller is null and no products are loaded`() = runTest(dispatcher) {
        val vm = SalesViewModel(FakeSellerRepository(seller = null), FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        assertNull(vm.state.value.seller)
        assertTrue(vm.state.value.products.isEmpty())
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `an approved seller's products are loaded`() = runTest(dispatcher) {
        val vm = SalesViewModel(
            FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT)),
            FakeAddressRepository(),
            FakeEarningsRepository(),
        )
        advanceUntilIdle()

        assertEquals(APPROVED_SELLER, vm.state.value.seller)
        assertEquals(1, vm.state.value.products.size)
    }

    @Test fun `submitApplication sends the composed draft and stores the resulting seller`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = null)
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.onBusinessNameChange("Kedai Test")
        vm.onCommunitySelected(KEPAYAN)
        assertTrue(vm.state.value.applicationForm.canSubmit)

        vm.submitApplication(); advanceUntilIdle()

        assertNotNull(vm.state.value.seller)
        assertEquals("Kedai Test", vm.state.value.seller?.businessName)
        assertFalse(vm.state.value.isSubmittingApplication)
    }

    @Test fun `a failed application surfaces the error`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = null, applyResult = AppResult.Failure(AppError.Server("SELLER_APPLICATION_EXISTS")))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.onBusinessNameChange("Kedai Test")
        vm.onCommunitySelected(KEPAYAN)
        vm.submitApplication(); advanceUntilIdle()

        assertNull(vm.state.value.seller)
        assertEquals(AppError.Server("SELLER_APPLICATION_EXISTS"), vm.state.value.error)
    }

    @Test fun `submitProduct creates a new draft and prepends it to the catalog`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, products = emptyList())
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.openNewProductForm()
        vm.onProductTitleChange("Ikan Bilis")
        vm.onProductCategoryChange(KirimCategory.HASIL_LAUT)
        vm.onProductPriceChange("15.00")
        vm.onProductWeightChange("500")
        assertTrue(vm.state.value.productForm!!.canSubmit)

        vm.submitProduct(); advanceUntilIdle()

        assertEquals(1, vm.state.value.products.size)
        assertEquals("Ikan Bilis", vm.state.value.products.first().title)
        assertNull(vm.state.value.productForm)
    }

    @Test fun `an approved seller's orders are loaded alongside products, tab defaults to Dashboard`() = runTest(dispatcher) {
        val order = SellerOrder(
            id = "o1", referenceCode = "ORD-2609-000001", status = OrderStatus.CREATED,
            goodsSubtotalSen = Sen(3000), deliveryFeeSen = Sen(0), discountSen = Sen(0), commissionSen = Sen(300),
            totalSen = Sen(3000), createdAt = "2026-09-10T00:00:00Z",
            items = listOf(SellerOrderItem(titleSnapshot = "Ikan Bilis", priceSen = Sen(1500), quantity = 2, lineTotalSen = Sen(3000))),
        )
        val vm = SalesViewModel(
            FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT), orders = listOf(order)),
            FakeAddressRepository(),
            FakeEarningsRepository(),
        )
        advanceUntilIdle()

        assertEquals(SalesTab.DASHBOARD, vm.state.value.selectedTab)
        assertEquals(1, vm.state.value.orders.size)
        assertEquals("ORD-2609-000001", vm.state.value.orders.first().referenceCode)
        assertEquals(Sen(2700), vm.state.value.orders.first().netPayableSen)

        vm.selectTab(SalesTab.ORDERS)
        assertEquals(SalesTab.ORDERS, vm.state.value.selectedTab)
    }

    @Test fun `setProductStatus calls the repository and reloads the catalog`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.setProductStatus("p1", ProductStatus.PENDING_REVIEW); advanceUntilIdle()

        assertEquals(1, repo.setStatusCalls)
        assertEquals(ProductStatus.PENDING_REVIEW, repo.lastStatus)
        assertNull(vm.state.value.transitioningProductId)
    }

    // ── Product form validation ─────────────────────────────────────────────

    @Test fun `product form cannot submit without a title, category, price, or weight`() {
        val base = ProductFormState()
        assertFalse(base.canSubmit)

        assertFalse(base.copy(title = "Ik", category = KirimCategory.HASIL_LAUT, priceRinggit = "10", weightGrams = "500").canSubmit)
        assertFalse(base.copy(title = "Ikan Bilis", priceRinggit = "10", weightGrams = "500").canSubmit)
        assertFalse(base.copy(title = "Ikan Bilis", category = KirimCategory.HASIL_LAUT, priceRinggit = "0", weightGrams = "500").canSubmit)
        assertFalse(base.copy(title = "Ikan Bilis", category = KirimCategory.HASIL_LAUT, priceRinggit = "10", weightGrams = "0").canSubmit)

        assertTrue(base.copy(title = "Ikan Bilis", category = KirimCategory.HASIL_LAUT, priceRinggit = "10", weightGrams = "500").canSubmit)
    }

    @Test fun `product form converts ringgit price to sen and defaults a blank min order qty to 1`() {
        val form = ProductFormState(
            title = "Ikan Bilis", category = KirimCategory.HASIL_LAUT, priceRinggit = "15.50",
            unit = "kg", weightGrams = "500", minOrderQty = "",
        )
        val draft = form.toDraftOrNull()

        assertNotNull(draft)
        assertEquals(1550L, draft!!.priceSen)
        assertEquals(1, draft.minOrderQty)
    }

    @Test fun `an incomplete product form produces no draft`() {
        assertNull(ProductFormState(title = "Ikan Bilis").toDraftOrNull())
    }

    // ── Inventory state (stock dialog) ──────────────────────────────────────

    @Test fun `stock dialog input parses only non-negative on-hand and safety values`() {
        val dialog = StockDialogState(productId = "p1", current = null, onHandInput = "12", safetyStockInput = "3")

        assertEquals(12, dialog.onHandOrNull)
        assertEquals(3, dialog.safetyStockOrNull)
        assertNull(dialog.copy(onHandInput = "-1").onHandOrNull)
        assertNull(dialog.copy(safetyStockInput = "").safetyStockOrNull)
    }

    @Test fun `stock dialog adjust delta rejects zero and blank input but allows negative deltas`() {
        val dialog = StockDialogState(productId = "p1", current = null, onHandInput = "0", safetyStockInput = "0")

        assertNull(dialog.copy(adjustDeltaInput = "0").adjustDeltaOrNull)
        assertNull(dialog.copy(adjustDeltaInput = "").adjustDeltaOrNull)
        assertEquals(5, dialog.copy(adjustDeltaInput = "5").adjustDeltaOrNull)
        assertEquals(-3, dialog.copy(adjustDeltaInput = "-3").adjustDeltaOrNull)
    }

    @Test fun `openStockDialog seeds the current server figures and loads movement history`() = runTest(dispatcher) {
        val inv = Inventory(onHand = 10, reserved = 2, safetyStock = 4, available = 8)
        val product = DRAFT_PRODUCT.copy(inventory = inv)
        val movement = InventoryMovement(id = "m1", delta = 10, reason = "seller_set", createdAt = "2026-09-10T00:00:00Z")
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(product), movements = listOf(movement))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.openStockDialog(product); advanceUntilIdle()

        val dialog = vm.state.value.stockDialog
        assertNotNull(dialog)
        assertEquals(inv, dialog!!.current)
        assertEquals("10", dialog.onHandInput)
        assertEquals("4", dialog.safetyStockInput)
        assertEquals(1, dialog.movements.size)
    }

    @Test fun `saveStockAbsolute applies the server's response to the product and refreshes the dashboard`() = runTest(dispatcher) {
        val product = DRAFT_PRODUCT.copy(inventory = Inventory(onHand = 5, reserved = 0, safetyStock = 2, available = 5))
        val updated = Inventory(onHand = 20, reserved = 0, safetyStock = 2, available = 20)
        val repo = FakeSellerRepository(
            seller = APPROVED_SELLER, products = listOf(product), setStockResult = AppResult.Success(updated),
            dashboardResult = AppResult.Success(SellerDashboard(1, 1, 0, 0, 0)),
        )
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.openStockDialog(product); advanceUntilIdle()
        vm.onStockOnHandChange("20")
        vm.saveStockAbsolute(); advanceUntilIdle()

        assertEquals(20, repo.lastSetStockOnHand)
        assertEquals(updated, vm.state.value.products.first().inventory)
        assertEquals(updated, vm.state.value.stockDialog?.current)
        assertFalse(vm.state.value.stockDialog!!.isSaving)
        assertEquals(0, vm.state.value.dashboard?.lowStockCount)
    }

    @Test fun `a stock adjustment the server refuses surfaces the error and stops saving`() = runTest(dispatcher) {
        val product = DRAFT_PRODUCT.copy(inventory = Inventory(onHand = 5, reserved = 4, safetyStock = 2, available = 1))
        val repo = FakeSellerRepository(
            seller = APPROVED_SELLER, products = listOf(product),
            adjustStockResult = AppResult.Failure(AppError.Server("STOCK_BELOW_RESERVED")),
        )
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.openStockDialog(product); advanceUntilIdle()
        vm.onStockAdjustDeltaChange("-100")
        vm.applyStockAdjustment(); advanceUntilIdle()

        assertEquals(AppError.Server("STOCK_BELOW_RESERVED"), vm.state.value.error)
        assertFalse(vm.state.value.stockDialog!!.isSaving)
        assertEquals(5, vm.state.value.products.first().inventory?.onHand)
    }

    // ── Seller order mapping & payment/status presentation ─────────────────

    @Test fun `netPayableSen is the goods subtotal net of commission, excluding delivery fee and total`() {
        val order = SellerOrder(
            id = "o1", referenceCode = "ORD-1", status = OrderStatus.PAID,
            goodsSubtotalSen = Sen(5000), deliveryFeeSen = Sen(800), discountSen = Sen(0), commissionSen = Sen(500),
            totalSen = Sen(5800), createdAt = "2026-09-10T00:00:00Z", items = emptyList(),
        )
        assertEquals(Sen(4500), order.netPayableSen)
    }

    @Test fun `selectOrder loads the order's payment and delivery status from the server`() = runTest(dispatcher) {
        val order = SellerOrder(
            id = "o1", referenceCode = "ORD-1", status = OrderStatus.PAID,
            goodsSubtotalSen = Sen(3000), deliveryFeeSen = Sen(0), discountSen = Sen(0), commissionSen = Sen(300),
            totalSen = Sen(3000), createdAt = "2026-09-10T00:00:00Z", items = emptyList(),
        )
        val status = SellerOrderStatus(
            orderStatus = OrderStatus.PAID, paymentStatus = "CAPTURED", paymentMethod = "BILLPLZ_FPX",
            deliveryId = "d1", deliveryStatus = "IN_TRANSIT", carrierAssigned = true,
        )
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, orders = listOf(order), orderStatusResult = AppResult.Success(status))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.selectOrder(order); advanceUntilIdle()

        assertEquals(order, vm.state.value.selectedOrder)
        assertEquals(status, vm.state.value.selectedOrderStatus)
        assertFalse(vm.state.value.isLoadingOrderStatus)
    }

    @Test fun `dismissOrderDetail clears the selected order and its status`() = runTest(dispatcher) {
        val order = SellerOrder(
            id = "o1", referenceCode = "ORD-1", status = OrderStatus.PAID,
            goodsSubtotalSen = Sen(3000), deliveryFeeSen = Sen(0), discountSen = Sen(0), commissionSen = Sen(300),
            totalSen = Sen(3000), createdAt = "2026-09-10T00:00:00Z", items = emptyList(),
        )
        val vm = SalesViewModel(
            FakeSellerRepository(seller = APPROVED_SELLER, orders = listOf(order)), FakeAddressRepository(), FakeEarningsRepository(),
        )
        advanceUntilIdle()

        vm.selectOrder(order); advanceUntilIdle()
        vm.dismissOrderDetail()

        assertNull(vm.state.value.selectedOrder)
        assertNull(vm.state.value.selectedOrderStatus)
    }

    @Test fun `confirmDispute opens the dispute via the delivery id and keeps the confirmation flag set`() = runTest(dispatcher) {
        val order = SellerOrder(
            id = "o1", referenceCode = "ORD-1", status = OrderStatus.FULFILLED,
            goodsSubtotalSen = Sen(3000), deliveryFeeSen = Sen(0), discountSen = Sen(0), commissionSen = Sen(300),
            totalSen = Sen(3000), createdAt = "2026-09-10T00:00:00Z", items = emptyList(),
        )
        val status = SellerOrderStatus(
            orderStatus = OrderStatus.FULFILLED, paymentStatus = "CAPTURED", paymentMethod = "COD",
            deliveryId = "d1", deliveryStatus = "DELIVERED", carrierAssigned = true,
        )
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, orders = listOf(order), orderStatusResult = AppResult.Success(status))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.selectOrder(order); advanceUntilIdle()
        vm.openDisputeConfirm()
        vm.confirmDispute(); advanceUntilIdle()

        assertEquals("d1", repo.lastDisputeDeliveryId)
        assertTrue(vm.state.value.disputeSubmitted)
        assertFalse(vm.state.value.showDisputeConfirm)
        assertFalse(vm.state.value.isFilingDispute)
        assertNotNull(vm.state.value.selectedOrderStatus)
    }

    @Test fun `confirmDispute does nothing when the order has no delivery id yet`() = runTest(dispatcher) {
        val order = SellerOrder(
            id = "o1", referenceCode = "ORD-1", status = OrderStatus.PENDING_PAYMENT,
            goodsSubtotalSen = Sen(3000), deliveryFeeSen = Sen(0), discountSen = Sen(0), commissionSen = Sen(300),
            totalSen = Sen(3000), createdAt = "2026-09-10T00:00:00Z", items = emptyList(),
        )
        val status = SellerOrderStatus(
            orderStatus = OrderStatus.PENDING_PAYMENT, paymentStatus = "COD_PENDING", paymentMethod = "COD",
            deliveryId = null, deliveryStatus = null, carrierAssigned = false,
        )
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, orders = listOf(order), orderStatusResult = AppResult.Success(status))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.selectOrder(order); advanceUntilIdle()
        vm.confirmDispute(); advanceUntilIdle()

        assertNull(repo.lastDisputeDeliveryId)
        assertFalse(vm.state.value.disputeSubmitted)
    }

    // ── Seller earnings & dashboard presentation ────────────────────────────

    @Test fun `loading a seller populates dashboard counts and the seller half of earnings`() = runTest(dispatcher) {
        val dashboard = SellerDashboard(productCount = 5, activeListings = 3, lowStockCount = 1, pendingOrders = 2, completedOrders = 10)
        val earnings = Earnings(
            availableSen = Sen.ZERO, pendingSen = Sen.ZERO, codHeldSen = null, floatLimitSen = null,
            sellerAvailableSen = Sen(12000), sellerPendingSen = Sen(3000),
        )
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, dashboardResult = AppResult.Success(dashboard))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository(result = AppResult.Success(earnings)))
        advanceUntilIdle()

        assertEquals(dashboard, vm.state.value.dashboard)
        assertEquals(Sen(12000), vm.state.value.earnings?.sellerAvailableSen)
        assertEquals(Sen(3000), vm.state.value.earnings?.sellerPendingSen)
        assertFalse(vm.state.value.isLoadingDashboard)
    }

    @Test fun `a dashboard load failure surfaces the error and leaves the dashboard unset`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, dashboardResult = AppResult.Failure(AppError.Network))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        assertEquals(AppError.Network, vm.state.value.error)
        assertNull(vm.state.value.dashboard)
        assertFalse(vm.state.value.isLoadingDashboard)
    }

    // ── Archive & error states ───────────────────────────────────────────────

    @Test fun `confirmArchiveProduct removes the product from the catalog on success`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT))
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.openArchiveConfirm("p1")
        vm.confirmArchiveProduct(); advanceUntilIdle()

        assertEquals("p1", repo.lastArchivedId)
        assertTrue(vm.state.value.products.isEmpty())
        assertNull(vm.state.value.archiveConfirmProductId)
        assertFalse(vm.state.value.isArchivingProduct)
    }

    @Test fun `a failed archive keeps the product listed and surfaces the error`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(
            seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT),
            archiveResult = AppResult.Failure(AppError.Server("PRODUCT_HAS_OPEN_ORDERS")),
        )
        val vm = SalesViewModel(repo, FakeAddressRepository(), FakeEarningsRepository())
        advanceUntilIdle()

        vm.openArchiveConfirm("p1")
        vm.confirmArchiveProduct(); advanceUntilIdle()

        assertEquals(1, vm.state.value.products.size)
        assertEquals(AppError.Server("PRODUCT_HAS_OPEN_ORDERS"), vm.state.value.error)
        assertFalse(vm.state.value.isArchivingProduct)
    }
}
