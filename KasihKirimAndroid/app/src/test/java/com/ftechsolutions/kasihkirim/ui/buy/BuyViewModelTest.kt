package com.ftechsolutions.kasihkirim.ui.buy

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutOrderSummary
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.PaymentStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val KEPAYAN = Community(id = "c1", name = "Kg Kepayan Baru", type = "kampung", district = "Kota Kinabalu", state = "Sabah", nodeId = "n1")

private val ADDRESS = Address(
    id = "a1", label = "Rumah", recipientName = "Aisyah", recipientPhone = "+60198765432",
    community = KEPAYAN, landmarkNote = "Sebelah surau", isDefault = true,
)

private val LISTING = BuyListing(
    id = "p1", title = "Ikan Bilis", priceSen = Sen(1500), unit = "kg",
    weightGrams = 500, minOrderQty = 1, sellerId = "s1", sellerName = "Kedai Siti", imagePath = null,
)

private val CART_LINE = CartLine(
    cartItemId = "ci1", productId = "p1", title = "Ikan Bilis", priceSen = Sen(1500),
    unit = "kg", sellerId = "s1", quantity = 2,
)

private class FakeAddressRepository(var addresses: List<Address> = listOf(ADDRESS)) : AddressRepository {
    override suspend fun listAddresses(): AppResult<List<Address>> = AppResult.Success(addresses)
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()
    override suspend fun searchCommunities(query: String) = throw NotImplementedError()
}

private class FakeBuyRepository(
    var listings: List<BuyListing> = listOf(LISTING),
    var cart: List<CartLine> = emptyList(),
    var checkoutResult: AppResult<CheckoutResult>? = null,
) : BuyRepository {
    var addToCartCalls = 0
    var checkoutCalls = 0
    var lastCheckoutVoucher: String? = null
    var lastCheckoutMethod: String? = null
    var paymentIntentUrl: AppResult<String> = AppResult.Success("https://www.billplz-sandbox.com/bills/test")
    var paymentStatus: AppResult<PaymentStatusInfo>? = null

    override suspend fun browseProducts(query: String): AppResult<List<BuyListing>> = AppResult.Success(listings)
    override suspend fun getCart(): AppResult<List<CartLine>> = AppResult.Success(cart)

    override suspend fun addToCart(productId: String, quantity: Int): AppResult<Unit> {
        addToCartCalls++
        cart = listOf(CART_LINE)
        return AppResult.Success(Unit)
    }

    override suspend fun updateCartQuantity(cartItemId: String, quantity: Int): AppResult<Unit> {
        cart = cart.map { if (it.cartItemId == cartItemId) it.copy(quantity = quantity) else it }
        return AppResult.Success(Unit)
    }

    override suspend fun removeFromCart(cartItemId: String): AppResult<Unit> {
        cart = cart.filterNot { it.cartItemId == cartItemId }
        return AppResult.Success(Unit)
    }

    override suspend fun checkout(
        destAddressId: String,
        voucherCode: String?,
        paymentMethod: String,
    ): AppResult<CheckoutResult> {
        checkoutCalls++
        lastCheckoutVoucher = voucherCode
        lastCheckoutMethod = paymentMethod
        return checkoutResult ?: AppResult.Success(
            CheckoutResult(
                orderGroupId = "g1",
                orders = listOf(
                    CheckoutOrderSummary(
                        orderId = "o1", referenceCode = "ORD-1", sellerId = "s1",
                        goodsSubtotalSen = Sen(3000), discountSen = Sen.ZERO, totalSen = Sen(3000),
                        paymentId = "pay1", paymentStatus = "COD_PENDING", paymentMethod = paymentMethod,
                    ),
                ),
            ),
        )
    }

    override suspend fun claimVoucher(campaignId: String) = throw NotImplementedError()

    override suspend fun createPaymentIntent(orderId: String): AppResult<String> = paymentIntentUrl

    override suspend fun getPaymentStatus(orderId: String): AppResult<PaymentStatusInfo> =
        paymentStatus ?: AppResult.Success(
            PaymentStatusInfo(
                paymentId = "pay1", status = "PENDING", method = "FPX",
                amountSen = Sen(3000), checkoutUrl = null, orderStatus = "PENDING_PAYMENT",
            ),
        )

    override suspend fun listMyOrders(): AppResult<List<BuyOrder>> = throw NotImplementedError()

    override suspend fun fileDispute(orderId: String, category: String, description: String) =
        throw NotImplementedError()
}

@OptIn(ExperimentalCoroutinesApi::class)
class BuyViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `listings, cart, and addresses load on init, defaulting to the default address`() = runTest(dispatcher) {
        val vm = BuyViewModel(FakeBuyRepository(), FakeAddressRepository())
        advanceUntilIdle()

        assertEquals(1, vm.state.value.listings.size)
        assertEquals("a1", vm.state.value.selectedAddressId)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `addToCart calls the repository and reloads the cart`() = runTest(dispatcher) {
        val repo = FakeBuyRepository()
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.addToCart("p1"); advanceUntilIdle()

        assertEquals(1, repo.addToCartCalls)
        assertEquals(1, vm.state.value.cart.size)
    }

    @Test fun `cartTotalSen and cartSpansMultipleSellers reflect the loaded cart`() = runTest(dispatcher) {
        val secondSellerLine = CART_LINE.copy(cartItemId = "ci2", sellerId = "s2", quantity = 1)
        val repo = FakeBuyRepository(cart = listOf(CART_LINE, secondSellerLine))
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        assertEquals(CART_LINE.lineTotalSen.value + secondSellerLine.lineTotalSen.value, vm.state.value.cartTotalSen)
        assertTrue(vm.state.value.cartSpansMultipleSellers)
    }

    @Test fun `checkout succeeds and clears the cart and voucher input`() = runTest(dispatcher) {
        val repo = FakeBuyRepository(cart = listOf(CART_LINE))
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onVoucherCodeChange("SAVE5")
        vm.checkout(); advanceUntilIdle()

        assertEquals(1, repo.checkoutCalls)
        assertEquals("SAVE5", repo.lastCheckoutVoucher)
        assertNotNull(vm.state.value.checkoutResult)
        assertTrue(vm.state.value.cart.isEmpty())
        assertEquals("", vm.state.value.voucherCode)
        assertFalse(vm.state.value.isCheckingOut)
    }

    @Test fun `a failed checkout surfaces the error and keeps the cart`() = runTest(dispatcher) {
        val repo = FakeBuyRepository(
            cart = listOf(CART_LINE),
            checkoutResult = AppResult.Failure(AppError.Server("INSUFFICIENT_STOCK")),
        )
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.checkout(); advanceUntilIdle()

        assertEquals(AppError.Server("INSUFFICIENT_STOCK"), vm.state.value.error)
        assertNull(vm.state.value.checkoutResult)
        assertEquals(1, vm.state.value.cart.size)
    }

    @Test fun `checkout forces COD when the cart spans multiple sellers even if online was selected`() = runTest(dispatcher) {
        val secondSellerLine = CART_LINE.copy(cartItemId = "ci2", sellerId = "s2", quantity = 1)
        val repo = FakeBuyRepository(cart = listOf(CART_LINE, secondSellerLine))
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onPaymentMethodSelected("FPX")
        vm.checkout(); advanceUntilIdle()

        assertEquals("COD", repo.lastCheckoutMethod)
    }

    @Test fun `checkout passes the selected online method for a single-seller cart`() = runTest(dispatcher) {
        val repo = FakeBuyRepository(cart = listOf(CART_LINE))
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onPaymentMethodSelected("FPX")
        vm.checkout(); advanceUntilIdle()

        assertEquals("FPX", repo.lastCheckoutMethod)
        assertEquals("FPX", vm.state.value.checkoutResult?.orders?.single()?.paymentMethod)
    }

    @Test fun `payNow opens the hosted page and stops polling once the payment reaches a terminal status`() = runTest(dispatcher) {
        val repo = FakeBuyRepository(cart = listOf(CART_LINE)).apply {
            paymentStatus = AppResult.Success(
                PaymentStatusInfo(
                    paymentId = "pay1", status = "SUCCEEDED", method = "FPX",
                    amountSen = Sen(3000), checkoutUrl = "https://www.billplz-sandbox.com/bills/test",
                    orderStatus = "PAID",
                ),
            )
        }
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.payNow("o1"); advanceUntilIdle()

        assertEquals("https://www.billplz-sandbox.com/bills/test", vm.state.value.pendingPaymentUrl)
        assertEquals("SUCCEEDED", vm.state.value.paymentStatus?.status)
        assertFalse(vm.state.value.isPollingPayment)
    }

    @Test fun `onPaymentUrlLaunched consumes the one-shot Custom Tab event`() = runTest(dispatcher) {
        val repo = FakeBuyRepository(cart = listOf(CART_LINE))
        val vm = BuyViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.payNow("o1"); advanceUntilIdle()
        assertNotNull(vm.state.value.pendingPaymentUrl)

        vm.onPaymentUrlLaunched()
        assertNull(vm.state.value.pendingPaymentUrl)
    }
}
