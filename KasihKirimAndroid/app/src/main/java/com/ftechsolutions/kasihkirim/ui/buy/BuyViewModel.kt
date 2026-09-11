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
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
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
    val isCheckingOut: Boolean = false,
    val checkoutResult: CheckoutResult? = null,
    /** A hosted Billplz page to open in a Custom Tab -- a one-shot event,
     *  consumed by BuyScreen's LaunchedEffect then cleared. */
    val pendingPaymentUrl: String? = null,
    val isPreparingPayment: Boolean = false,
    val isPollingPayment: Boolean = false,
    val paymentStatus: PaymentStatusInfo? = null,
    val error: AppError? = null,
) {
    val cartCount: Int get() = cart.sumOf { it.quantity }
    val cartTotalSen: Long get() = cart.sumOf { it.lineTotalSen.value }
    val cartSpansMultipleSellers: Boolean get() = cart.map { it.sellerId }.distinct().size > 1
}

class BuyViewModel(
    private val buyRepo: BuyRepository,
    private val addressRepo: AddressRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(BuyUiState())
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
                is AppResult.Failure -> Unit
            }
        }
    }

    fun addToCart(productId: String) {
        viewModelScope.launch {
            when (val result = buyRepo.addToCart(productId, quantity = 1)) {
                is AppResult.Success -> loadCart()
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
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

    fun checkout() {
        val addressId = _state.value.selectedAddressId ?: return
        val code = _state.value.voucherCode.trim().takeIf { it.isNotEmpty() }
        val method = if (_state.value.cartSpansMultipleSellers) "COD" else _state.value.paymentMethod
        viewModelScope.launch {
            _state.update { it.copy(isCheckingOut = true, error = null) }
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

    override fun onCleared() {
        pollingJob?.cancel()
        super.onCleared()
    }

    /** Manual DI, matching SalesViewModel.Factory (§9). */
    class Factory(
        private val buyRepo: BuyRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = BuyViewModel(buyRepo, addressRepo) as T
    }
}
