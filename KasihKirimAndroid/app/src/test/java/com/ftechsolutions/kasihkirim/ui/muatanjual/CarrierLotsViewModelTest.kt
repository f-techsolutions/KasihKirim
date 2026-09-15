package com.ftechsolutions.kasihkirim.ui.muatanjual

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierLot
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.Inventory
import com.ftechsolutions.kasihkirim.domain.model.InventoryMovement
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.LotStatus
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualOnboardingStatus
import com.ftechsolutions.kasihkirim.domain.model.NewLot
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerDashboard
import com.ftechsolutions.kasihkirim.domain.model.SellerOrder
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderStatus
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.repository.CarrierLotRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val ACTIVE_SELLER = Seller(
    id = "s1", businessName = "Rahman Trader", status = SellerStatus.NOT_STARTED, communityId = "c1",
    ssmRegNo = null, sellerKind = "carrier_trader", onboardingStatus = MuatanJualOnboardingStatus.ACTIVE,
)

private val SAMPLE_LOT = CarrierLot(
    id = "lot-1", title = "Ikan Kering", status = LotStatus.DRAFT, handlingFlags = listOf(HandlingFlag.PERISHABLE),
    unit = "kg", qtyTotal = 10.0, qtyReserved = 0.0, qtySold = 0.0, costBasisSen = Sen(15000),
    pricePerUnitSen = Sen(2500), tripId = null, sellBy = null, createdAt = "2026-09-15T00:00:00Z",
)

private class FakeCarrierLotRepository(
    var lots: List<CarrierLot> = emptyList(),
    var createResult: AppResult<String> = AppResult.Success("lot-new"),
    var attachResult: AppResult<Unit> = AppResult.Success(Unit),
    var withdrawResult: AppResult<Unit> = AppResult.Success(Unit),
) : CarrierLotRepository {
    var createCalls = 0
    var lastDraft: NewLot? = null
    var attachCalls = 0
    var lastAttachLotId: String? = null
    var lastAttachTripId: String? = null
    var withdrawCalls = 0
    var lastWithdrawLotId: String? = null

    override suspend fun listMyLots(carrierId: String): AppResult<List<CarrierLot>> = AppResult.Success(lots)

    override suspend fun createLot(draft: NewLot): AppResult<String> {
        createCalls++
        lastDraft = draft
        return createResult
    }

    override suspend fun attachLotToTrip(lotId: String, tripId: String): AppResult<Unit> {
        attachCalls++
        lastAttachLotId = lotId
        lastAttachTripId = tripId
        return attachResult
    }

    override suspend fun withdrawLot(lotId: String): AppResult<Unit> {
        withdrawCalls++
        lastWithdrawLotId = lotId
        return withdrawResult
    }

    override suspend fun uploadLotPhoto(photoBytes: ByteArray): AppResult<String> = AppResult.Success("photo-path")
    override suspend fun uploadLotReceipt(photoBytes: ByteArray): AppResult<String> = AppResult.Success("receipt-path")
}

private class FakeSellerRepository(
    var seller: Seller? = ACTIVE_SELLER,
    var acceptResult: AppResult<Unit> = AppResult.Success(Unit),
) : SellerRepository {
    var acceptCalls = 0

    override suspend fun getMySellerApplication(): AppResult<Seller?> = AppResult.Success(seller)
    override suspend fun applySeller(draft: NewSeller): AppResult<Seller> = AppResult.Success(ACTIVE_SELLER)
    override suspend fun acceptMuatanJualTerms(): AppResult<Unit> { acceptCalls++; return acceptResult }
    override suspend fun listMyProducts(sellerId: String): AppResult<List<Product>> = AppResult.Success(emptyList())
    override suspend fun createProduct(draft: NewProduct): AppResult<Product> = AppResult.Failure(AppError.Unexpected)
    override suspend fun updateProduct(id: String, draft: NewProduct): AppResult<Product> =
        AppResult.Failure(AppError.Unexpected)
    override suspend fun setProductStatus(id: String, status: ProductStatus): AppResult<Unit> = AppResult.Success(Unit)
    override suspend fun uploadProductImage(productId: String, sortOrder: Int, photoBytes: ByteArray): AppResult<ProductImage> =
        AppResult.Failure(AppError.Unexpected)
    override suspend fun deleteProductImage(imageId: String, storagePath: String): AppResult<Unit> = AppResult.Success(Unit)
    override suspend fun listMyOrders(sellerId: String): AppResult<List<SellerOrder>> = AppResult.Success(emptyList())
    override suspend fun getDashboard(): AppResult<SellerDashboard> =
        AppResult.Success(SellerDashboard(0, 0, 0, 0, 0))
    override suspend fun setStock(productId: String, onHand: Int, safetyStock: Int?): AppResult<Inventory> =
        AppResult.Failure(AppError.Unexpected)
    override suspend fun adjustStock(productId: String, delta: Int, reason: String): AppResult<Inventory> =
        AppResult.Failure(AppError.Unexpected)
    override suspend fun listStockMovements(productId: String): AppResult<List<InventoryMovement>> =
        AppResult.Success(emptyList())
    override suspend fun archiveProduct(id: String): AppResult<Unit> = AppResult.Success(Unit)
    override suspend fun getOrderStatus(orderId: String): AppResult<SellerOrderStatus> =
        AppResult.Failure(AppError.Unexpected)
    override suspend fun openOrderDispute(deliveryId: String, category: String, description: String): AppResult<Unit> =
        AppResult.Success(Unit)
}

private class FakeTripRepository(var trips: List<Trip> = emptyList()) : TripRepository {
    override suspend fun listMyTrips(): AppResult<List<Trip>> = AppResult.Success(trips)
    override suspend fun createTrip(draft: NewTripDraft): AppResult<Trip> = AppResult.Failure(AppError.Unexpected)
    override suspend fun acceptOffer(tripId: String, kirimId: String): AppResult<Unit> = AppResult.Success(Unit)
    override suspend fun sendCapacityInvite(tripId: String): AppResult<Int> = AppResult.Success(0)
}

private val SAMPLE_TRIP = Trip(
    id = "trip-1", status = TripStatus.BOARDING, originNodeId = "n1", destNodeId = "n2",
    departAt = "2026-09-20T00:00:00Z", capacityWeightGrams = 10000, capacityVolumeCm3 = 500000,
    capacityParcels = 5, reservedWeightGrams = 0, reservedVolumeCm3 = 0, reservedParcels = 0,
)

@OptIn(ExperimentalCoroutinesApi::class)
class CarrierLotsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `no seller application shows null seller`() = runTest(dispatcher) {
        val vm = CarrierLotsViewModel(
            FakeCarrierLotRepository(), FakeSellerRepository(seller = null), FakeTripRepository(), "carrier-1",
        )
        advanceUntilIdle()

        assertNull(vm.state.value.seller)
        assertTrue(vm.state.value.lots.isEmpty())
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `an ACTIVE seller loads their own lots`() = runTest(dispatcher) {
        val vm = CarrierLotsViewModel(
            FakeCarrierLotRepository(lots = listOf(SAMPLE_LOT)), FakeSellerRepository(), FakeTripRepository(), "carrier-1",
        )
        advanceUntilIdle()

        assertEquals(ACTIVE_SELLER, vm.state.value.seller)
        assertEquals(listOf(SAMPLE_LOT), vm.state.value.lots)
    }

    @Test fun `attachable trips are filtered to DRAFT, ANNOUNCED and BOARDING`() = runTest(dispatcher) {
        val departed = SAMPLE_TRIP.copy(id = "trip-departed", status = TripStatus.DEPARTED)
        val vm = CarrierLotsViewModel(
            FakeCarrierLotRepository(), FakeSellerRepository(), FakeTripRepository(trips = listOf(SAMPLE_TRIP, departed)), "carrier-1",
        )
        advanceUntilIdle()

        assertEquals(listOf(SAMPLE_TRIP), vm.state.value.attachableTrips)
    }

    @Test fun `acceptTerms calls the repository and reloads`() = runTest(dispatcher) {
        val sellerRepo = FakeSellerRepository(seller = ACTIVE_SELLER.copy(onboardingStatus = MuatanJualOnboardingStatus.APPROVED))
        val vm = CarrierLotsViewModel(FakeCarrierLotRepository(), sellerRepo, FakeTripRepository(), "carrier-1")
        advanceUntilIdle()

        vm.acceptTerms(); advanceUntilIdle()

        assertEquals(1, sellerRepo.acceptCalls)
        assertFalse(vm.state.value.isAcceptingTerms)
    }

    @Test fun `submitCreate is a no-op without a captured receipt`() = runTest(dispatcher) {
        val lotRepo = FakeCarrierLotRepository()
        val vm = CarrierLotsViewModel(lotRepo, FakeSellerRepository(), FakeTripRepository(), "carrier-1")
        advanceUntilIdle()

        vm.openCreateForm()
        vm.onCreateTitleChange("Sayur Segar")
        vm.onCreateQtyChange("5")
        vm.onCreateCostBasisChange("50")
        vm.onCreatePriceChange("10")
        vm.submitCreate(); advanceUntilIdle()

        assertEquals(0, lotRepo.createCalls)
    }

    @Test fun `submitCreate sends the draft once a receipt is captured, then reloads`() = runTest(dispatcher) {
        val lotRepo = FakeCarrierLotRepository()
        val vm = CarrierLotsViewModel(lotRepo, FakeSellerRepository(), FakeTripRepository(), "carrier-1")
        advanceUntilIdle()

        vm.openCreateForm()
        vm.onCreateTitleChange("Sayur Segar")
        vm.onCreateCategoryChange(KirimCategory.SAYUR)
        vm.onCreateQtyChange("5")
        vm.onCreateCostBasisChange("50")
        vm.onCreatePriceChange("10")
        vm.onToggleHandlingFlag(HandlingFlag.PERISHABLE)
        vm.captureReceipt(byteArrayOf(1, 2, 3)); advanceUntilIdle()
        vm.submitCreate(); advanceUntilIdle()

        assertEquals(1, lotRepo.createCalls)
        val draft = lotRepo.lastDraft!!
        assertEquals("Sayur Segar", draft.title)
        assertEquals("sayur", draft.categorySlug)
        assertEquals(5.0, draft.qtyTotal, 0.0)
        assertEquals(5000L, draft.costBasisSen)
        assertEquals(1000L, draft.pricePerUnitSen)
        assertEquals(listOf(HandlingFlag.PERISHABLE), draft.handlingFlags)
        assertEquals("receipt-path", draft.costReceiptPath)
        assertFalse(vm.state.value.showCreateForm)
    }

    @Test fun `a failed create surfaces the error and keeps the form open`() = runTest(dispatcher) {
        val lotRepo = FakeCarrierLotRepository(createResult = AppResult.Failure(AppError.Server("LOT_VALUE_EXCEEDS_LIMIT")))
        val vm = CarrierLotsViewModel(lotRepo, FakeSellerRepository(), FakeTripRepository(), "carrier-1")
        advanceUntilIdle()

        vm.openCreateForm()
        vm.onCreateTitleChange("Sayur Segar")
        vm.onCreateQtyChange("5")
        vm.onCreateCostBasisChange("250")
        vm.onCreatePriceChange("10")
        vm.captureReceipt(byteArrayOf(1)); advanceUntilIdle()
        vm.submitCreate(); advanceUntilIdle()

        assertTrue(vm.state.value.showCreateForm)
        assertEquals(AppError.Server("LOT_VALUE_EXCEEDS_LIMIT"), vm.state.value.error)
    }

    @Test fun `requestAttach opens the trip picker, attachToTrip calls the repository`() = runTest(dispatcher) {
        val lotRepo = FakeCarrierLotRepository(lots = listOf(SAMPLE_LOT))
        val vm = CarrierLotsViewModel(lotRepo, FakeSellerRepository(), FakeTripRepository(trips = listOf(SAMPLE_TRIP)), "carrier-1")
        advanceUntilIdle()

        vm.requestAttach("lot-1")
        assertEquals("lot-1", vm.state.value.attachingLotId)

        vm.attachToTrip("trip-1"); advanceUntilIdle()

        assertEquals(1, lotRepo.attachCalls)
        assertEquals("lot-1", lotRepo.lastAttachLotId)
        assertEquals("trip-1", lotRepo.lastAttachTripId)
        assertNull(vm.state.value.attachingLotId)
    }

    @Test fun `withdrawLot calls the repository and reloads`() = runTest(dispatcher) {
        val lotRepo = FakeCarrierLotRepository(lots = listOf(SAMPLE_LOT))
        val vm = CarrierLotsViewModel(lotRepo, FakeSellerRepository(), FakeTripRepository(), "carrier-1")
        advanceUntilIdle()

        vm.withdrawLot("lot-1"); advanceUntilIdle()

        assertEquals(1, lotRepo.withdrawCalls)
        assertEquals("lot-1", lotRepo.lastWithdrawLotId)
        assertNull(vm.state.value.busyLotId)
    }
}
