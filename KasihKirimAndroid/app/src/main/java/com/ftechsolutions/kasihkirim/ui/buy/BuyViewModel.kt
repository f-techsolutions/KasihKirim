package com.ftechsolutions.kasihkirim.ui.buy

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.CheckoutResult
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.PaymentStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.PromotionSubjectType
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import com.ftechsolutions.kasihkirim.domain.repository.PromotionRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** rpc_apply_payment_event's terminal statuses (0004/0034) -- once a payment
 *  reaches one of these, nothing further will change it, so polling can
 *  stop. */
private val TERMINAL_PAYMENT_STATUSES =
    setOf("SUCCEEDED", "CAPTURED", "FAILED", "CANCELLED", "EXPIRED")

data class BuyUiState(
    val isLoading: Boolean = true,
    val listings: List<BuyListing> = emptyList(),
    val searchQuery: String = "",
    val cart: List<CartLine> = emptyList(),
    val showCart: Boolean = false,
    val addresses: List<Address> = emptyList(),
    val selectedAddressId: String? = null,
    val voucherCode: String = "",
    /** "COD" or "FPX" -- see BuyScreen's payment method selector. Anything
     *  other than COD is sandbox-only (Billplz, P2-A) and forced back to
     *  COD server-side unless a project has deliberately enabled it. */
    val paymentMethod: String = "COD",
    /** The product currently being added, if any -- disables only that
     *  listing's own button, not the whole browse list. */
    val addingToCartProductId: String? = null,
    val showCheckoutConfirm: Boolean = false,
    val isCheckingOut: Boolean = false,
    val checkoutResult: CheckoutResult? = null,
    /** A hosted Billplz page to open in a Custom Tab -- a one-shot event,
     *  consumed by BuyScreen's LaunchedEffect then cleared. */
    val pendingPaymentUrl: String? = null,
    val isPreparingPayment: Boolean = false,
    val isPollingPayment: Boolean = false,
    val paymentStatus: PaymentStatusInfo? = null,
    /** A share-sheet request to launch, if any -- a one-shot event, consumed
     *  by BuyScreen's LaunchedEffect then cleared, the same pattern as
     *  pendingPaymentUrl above. Null both before a share is requested and
     *  after it's been launched. */
    val pendingShare: ShareRequest? = null,
    val isSharingProductId: String? = null,
    val error: AppError? = null,
) {
    val cartCount: Int get() = cart.sumOf { it.quantity }
    val cartTotalSen: Long get() = cart.sumOf { it.lineTotalSen.value }
    val cartSpansMultipleSellers: Boolean get() = cart.map { it.sellerId }.distinct().size > 1
}

/** Kongsi & Untung: what BuyScreen needs to build the Android share sheet
 *  message for a just-created promotion code. */
data class ShareRequest(val productTitle: String, val shareLink: String)

class BuyViewModel(
    private val buyRepo: BuyRepository,
    private val addressRepo: AddressRepository,
    private val promotionRepo: PromotionRepository,
    initialQuery: String = "",
) : ViewModel() {

    private val _state = MutableStateFlow(BuyUiState(searchQuery = initialQuery))
    val state: StateFlow<BuyUiState> = _state.asStateFlow()

    private var pollingJob: Job? = null

    init {
        loadProducts()
        loadCart()
        loadAddresses()
    }

    fun loadProducts() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = buyRepo.browseProducts(_state.value.searchQuery)) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, listings = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    fun onSearchQueryChange(query: String) {
        _state.update { it.copy(searchQuery = query) }
        loadProducts()
    }

    private fun loadCart() {
        viewModelScope.launch {
            when (val result = buyRepo.getCart()) {
                is AppResult.Success -> _state.update { it.copy(cart = result.data) }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    private fun loadAddresses() {
        viewModelScope.launch {
            when (val result = addressRepo.listAddresses()) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        addresses = result.data,
                        selectedAddressId = it.selectedAddressId
                            ?: result.data.firstOrNull { a -> a.isDefault }?.id
                            ?: result.data.firstOrNull()?.id,
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun addToCart(productId: String) {
        if (_state.value.addingToCartProductId != null) return
        viewModelScope.launch {
            _state.update { it.copy(addingToCartProductId = productId, error = null) }
            when (val result = buyRepo.addToCart(productId, quantity = 1)) {
                is AppResult.Success -> {
                    _state.update { it.copy(addingToCartProductId = null) }
                    loadCart()
                }
                is AppResult.Failure -> _state.update { it.copy(addingToCartProductId = null, error = result.error) }
            }
        }
    }

    fun updateCartQuantity(cartItemId: String, quantity: Int) {
        if (quantity <= 0) return removeFromCart(cartItemId)
        viewModelScope.launch {
            when (val result = buyRepo.updateCartQuantity(cartItemId, quantity)) {
                is AppResult.Success -> loadCart()
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun removeFromCart(cartItemId: String) {
        viewModelScope.launch {
            when (val result = buyRepo.removeFromCart(cartItemId)) {
                is AppResult.Success -> loadCart()
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun toggleCart(show: Boolean) = _state.update { it.copy(showCart = show) }

    fun onAddressSelected(id: String) = _state.update { it.copy(selectedAddressId = id) }

    fun onVoucherCodeChange(code: String) = _state.update { it.copy(voucherCode = code) }

    /** checkout() itself forces this back to "COD" for a multi-seller cart
     *  regardless of what was tapped here -- same restriction rpc_checkout
     *  already applies to a voucher code, because one online payment covers
     *  exactly one order. */
    fun onPaymentMethodSelected(method: String) = _state.update { it.copy(paymentMethod = method) }

    /** Opens a confirmation step rather than firing rpc_checkout on the same
     *  tap -- found in review: this was the one real-money commitment in the
     *  whole buyer flow (COD needs no further gate at all) with no
     *  confirmation step anywhere in the cart sheet. */
    fun requestCheckout() {
        if (_state.value.selectedAddressId == null) return
        _state.update { it.copy(showCheckoutConfirm = true) }
    }

    fun dismissCheckoutConfirm() = _state.update { it.copy(showCheckoutConfirm = false) }

    fun checkout() {
        val addressId = _state.value.selectedAddressId ?: return
        val code = _state.value.voucherCode.trim().takeIf { it.isNotEmpty() }
        val method = if (_state.value.cartSpansMultipleSellers) "COD" else _state.value.paymentMethod
        viewModelScope.launch {
            _state.update { it.copy(showCheckoutConfirm = false, isCheckingOut = true, error = null) }
            when (val result = buyRepo.checkout(addressId, code, method)) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        isCheckingOut = false, checkoutResult = result.data,
                        voucherCode = "", cart = emptyList(), paymentMethod = "COD",
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(isCheckingOut = false, error = result.error) }
            }
        }
    }

    /** Opens the hosted Billplz page for a just-checked-out non-COD order
     *  and starts polling for its capture (0034: the webhook that actually
     *  confirms payment lands server-side, with no push channel back to this
     *  client yet). */
    fun payNow(orderId: String) {
        viewModelScope.launch {
            _state.update { it.copy(isPreparingPayment = true, error = null) }
            when (val result = buyRepo.createPaymentIntent(orderId)) {
                is AppResult.Success -> {
                    _state.update { it.copy(isPreparingPayment = false, pendingPaymentUrl = result.data) }
                    startPollingPayment(orderId)
                }
                is AppResult.Failure -> _state.update { it.copy(isPreparingPayment = false, error = result.error) }
            }
        }
    }

    /** Consumes the one-shot Custom Tab launch so recomposition never
     *  re-opens it. */
    fun onPaymentUrlLaunched() = _state.update { it.copy(pendingPaymentUrl = null) }

    private fun startPollingPayment(orderId: String) {
        pollingJob?.cancel()
        pollingJob = viewModelScope.launch {
            _state.update { it.copy(isPollingPayment = true) }
            // ~1 minute at 3s intervals -- long enough for a buyer to finish
            // paying in the Custom Tab and switch back, short enough that a
            // truly abandoned checkout doesn't poll forever.
            repeat(20) {
                delay(3_000)
                when (val result = buyRepo.getPaymentStatus(orderId)) {
                    is AppResult.Success -> {
                        _state.update { it.copy(paymentStatus = result.data) }
                        if (result.data.status in TERMINAL_PAYMENT_STATUSES) return@launch
                    }
                    // A transient read failure is not a reason to stop
                    // watching a payment that might still be capturing.
                    is AppResult.Failure -> Unit
                }
            }
        }.also { job ->
            job.invokeOnCompletion { _state.update { it.copy(isPollingPayment = false) } }
        }
    }

    /** Manual "check again" -- a buyer who comes back well after polling
     *  gave up should not be stuck re-running checkout to find out. */
    fun refreshPaymentStatus(orderId: String) {
        viewModelScope.launch {
            when (val result = buyRepo.getPaymentStatus(orderId)) {
                is AppResult.Success -> _state.update { it.copy(paymentStatus = result.data) }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun dismissCheckoutResult() {
        pollingJob?.cancel()
        _state.update {
            it.copy(
                checkoutResult = null, showCart = false,
                pendingPaymentUrl = null, paymentStatus = null, isPollingPayment = false,
            )
        }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    /** Kongsi & Untung: mint (or re-fetch) this buyer's own share code for a
     *  product and hand the resulting link to BuyScreen as a one-shot share-
     *  sheet event. A no-op-with-error while the feature is off -- surfaced
     *  the same way any other RPC error is (KONGSI_UNTUNG_DISABLED). */
    fun shareProduct(listing: BuyListing) {
        if (_state.value.isSharingProductId != null) return
        viewModelScope.launch {
            _state.update { it.copy(isSharingProductId = listing.id, error = null) }
            when (val result = promotionRepo.createPromotion(PromotionSubjectType.PRODUCT, listing.id)) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        isSharingProductId = null,
                        pendingShare = ShareRequest(listing.title, result.data.shareLink),
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(isSharingProductId = null, error = result.error) }
            }
        }
    }

    /** Consumes the one-shot share-sheet launch so recomposition never
     *  re-opens it -- mirrors onPaymentUrlLaunched() above. */
    fun onShareLaunched() = _state.update { it.copy(pendingShare = null) }

    override fun onCleared() {
        pollingJob?.cancel()
        super.onCleared()
    }

    /** Manual DI, matching SalesViewModel.Factory (§9). initialQuery lets
     *  DealsGalleryScreen deep-link a tapped deal straight to its own
     *  product -- see BUY_ROUTE's own "?query={query}" argument. */
    class Factory(
        private val buyRepo: BuyRepository,
        private val addressRepo: AddressRepository,
        private val promotionRepo: PromotionRepository,
        private val initialQuery: String = "",
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            BuyViewModel(buyRepo, addressRepo, promotionRepo, initialQuery) as T
    }
}
