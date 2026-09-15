package com.ftechsolutions.kasihkirim.ui.buy

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.DeliveryStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.DisputeCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.OrderStatus
import com.ftechsolutions.kasihkirim.domain.model.PaymentStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderItem
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val COD_ORDER = BuyOrder(
    id = "o1", referenceCode = "ORD-1", status = OrderStatus.PAID, sellerId = "s1",
    goodsSubtotalSen = Sen(3000), deliveryFeeSen = Sen(500), totalSen = Sen(3500),
    paymentMethod = "COD", createdAt = "2026-09-10T00:00:00Z",
    items = listOf(SellerOrderItem(titleSnapshot = "Ikan Bilis", priceSen = Sen(1500), quantity = 2, lineTotalSen = Sen(3000))),
)

private val ONLINE_ORDER = COD_ORDER.copy(id = "o2", referenceCode = "ORD-2", paymentMethod = "FPX")

private class FakeBuyOrdersRepository(
    var orders: List<BuyOrder> = listOf(COD_ORDER),
    var deliveryStatusResult: AppResult<DeliveryStatusInfo?>? = null,
    var paymentStatusResult: AppResult<PaymentStatusInfo>? = null,
    var disputeResult: AppResult<Unit>? = null,
    var paymentIntentResult: AppResult<String>? = null,
) : BuyRepository {
    var disputeCalls = 0
    var lastDisputeCategory: String? = null
    var lastDisputeDescription: String? = null
    var deliveryStatusCalls = 0

    override suspend fun browseProducts(query: String): AppResult<List<BuyListing>> = throw NotImplementedError()
    override suspend fun getCart(): AppResult<List<CartLine>> = throw NotImplementedError()
    override suspend fun addToCart(productId: String, quantity: Int) = throw NotImplementedError()
    override suspend fun updateCartQuantity(cartItemId: String, quantity: Int) = throw NotImplementedError()
    override suspend fun removeFromCart(cartItemId: String) = throw NotImplementedError()
    override suspend fun checkout(destAddressId: String, voucherCode: String?, paymentMethod: String): AppResult<CheckoutResult> =
        throw NotImplementedError()
    override suspend fun claimVoucher(campaignId: String) = throw NotImplementedError()

    override suspend fun createPaymentIntent(orderId: String): AppResult<String> =
        paymentIntentResult ?: AppResult.Success("https://www.billplz-sandbox.com/bills/test")

    override suspend fun getPaymentStatus(orderId: String): AppResult<PaymentStatusInfo> =
        paymentStatusResult ?: AppResult.Success(
            PaymentStatusInfo(
                paymentId = "pay1", status = "PENDING", method = "FPX",
                amountSen = Sen(3500), checkoutUrl = null, orderStatus = "PENDING_PAYMENT",
            ),
        )

    override suspend fun listMyOrders(): AppResult<List<BuyOrder>> = AppResult.Success(orders)

    override suspend fun getDeliveryStatus(orderId: String): AppResult<DeliveryStatusInfo?> {
        deliveryStatusCalls++
        return deliveryStatusResult ?: AppResult.Success(
            DeliveryStatusInfo(kirimStatus = KirimStatus.MATCHED, carrierAssigned = true),
        )
    }

    override suspend fun fileDispute(orderId: String, category: String, description: String): AppResult<Unit> {
        disputeCalls++
        lastDisputeCategory = category
        lastDisputeDescription = description
        return disputeResult ?: AppResult.Success(Unit)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class BuyOrdersViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `orders load on init`() = runTest(dispatcher) {
        val vm = BuyOrdersViewModel(FakeBuyOrdersRepository())
        advanceUntilIdle()

        assertEquals(1, vm.state.value.orders.size)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `a failed order load surfaces the error`() = runTest(dispatcher) {
        val repo = object : BuyRepository by FakeBuyOrdersRepository() {
            override suspend fun listMyOrders() = AppResult.Failure(AppError.Network)
        }
        val vm = BuyOrdersViewModel(repo)
        advanceUntilIdle()

        assertEquals(AppError.Network, vm.state.value.error)
        assertTrue(vm.state.value.orders.isEmpty())
    }

    @Test fun `selectOrder loads delivery status but not payment status for a COD order`() = runTest(dispatcher) {
        val repo = FakeBuyOrdersRepository()
        val vm = BuyOrdersViewModel(repo)
        advanceUntilIdle()

        vm.selectOrder(COD_ORDER); advanceUntilIdle()

        assertEquals(COD_ORDER, vm.state.value.selectedOrder)
        assertNotNull(vm.state.value.deliveryStatus)
        assertEquals(KirimStatus.MATCHED, vm.state.value.deliveryStatus?.kirimStatus)
        assertNull("a COD order never needs a payment status poll", vm.state.value.paymentStatus)
        assertEquals(1, repo.deliveryStatusCalls)
    }

    @Test fun `selectOrder loads both payment and delivery status for a non-COD order`() = runTest(dispatcher) {
        val repo = FakeBuyOrdersRepository(orders = listOf(ONLINE_ORDER))
        val vm = BuyOrdersViewModel(repo)
        advanceUntilIdle()

        vm.selectOrder(ONLINE_ORDER); advanceUntilIdle()

        assertNotNull(vm.state.value.paymentStatus)
        assertNotNull(vm.state.value.deliveryStatus)
    }

    @Test fun `a null delivery status means the order has no kirim yet, not an error`() = runTest(dispatcher) {
        val repo = FakeBuyOrdersRepository(deliveryStatusResult = AppResult.Success(null))
        val vm = BuyOrdersViewModel(repo)
        advanceUntilIdle()

        vm.selectOrder(COD_ORDER); advanceUntilIdle()

        assertNull(vm.state.value.deliveryStatus)
        assertNull(vm.state.value.error)
        assertFalse(vm.state.value.isLoadingDeliveryStatus)
    }

    @Test fun `dismissOrderDetail clears the selected order and its delivery status`() = runTest(dispatcher) {
        val vm = BuyOrdersViewModel(FakeBuyOrdersRepository())
        advanceUntilIdle()

        vm.selectOrder(COD_ORDER); advanceUntilIdle()
        vm.dismissOrderDetail()

        assertNull(vm.state.value.selectedOrder)
        assertNull(vm.state.value.deliveryStatus)
    }

    @Test fun `submitDispute sends the selected order's id and category`() = runTest(dispatcher) {
        val repo = FakeBuyOrdersRepository()
        val vm = BuyOrdersViewModel(repo)
        advanceUntilIdle()

        vm.selectOrder(COD_ORDER); advanceUntilIdle()
        vm.onDisputeCategorySelected(DisputeCategory.DAMAGED)
        vm.onDisputeDescriptionChange("Barang pecah semasa sampai")
        vm.submitDispute(); advanceUntilIdle()

        assertEquals(1, repo.disputeCalls)
        assertEquals("damaged", repo.lastDisputeCategory)
        assertEquals("Barang pecah semasa sampai", repo.lastDisputeDescription)
        assertTrue(vm.state.value.disputeSubmitted)
        assertFalse(vm.state.value.showDisputeForm)
        assertFalse(vm.state.value.isFilingDispute)
    }

    @Test fun `a failed dispute surfaces the error and keeps the form open`() = runTest(dispatcher) {
        val repo = FakeBuyOrdersRepository(disputeResult = AppResult.Failure(AppError.Server("DELIVERY_NOT_FOUND")))
        val vm = BuyOrdersViewModel(repo)
        advanceUntilIdle()

        vm.selectOrder(COD_ORDER); advanceUntilIdle()
        vm.openDisputeForm()
        vm.submitDispute(); advanceUntilIdle()

        assertEquals(AppError.Server("DELIVERY_NOT_FOUND"), vm.state.value.error)
        assertFalse(vm.state.value.disputeSubmitted)
    }

    @Test fun `payNow opens the hosted payment page`() = runTest(dispatcher) {
        val vm = BuyOrdersViewModel(FakeBuyOrdersRepository(orders = listOf(ONLINE_ORDER)))
        advanceUntilIdle()

        vm.payNow("o2"); advanceUntilIdle()

        assertEquals("https://www.billplz-sandbox.com/bills/test", vm.state.value.pendingPaymentUrl)
        assertFalse(vm.state.value.isPreparingPayment)
    }
}
