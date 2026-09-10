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
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class BuyUiState(
    val isLoading: Boolean = true,
    val listings: List<BuyListing> = emptyList(),
    val searchQuery: String = "",
    val cart: List<CartLine> = emptyList(),
    val showCart: Boolean = false,
    val addresses: List<Address> = emptyList(),
    val selectedAddressId: String? = null,
    val voucherCode: String = "",
    val isCheckingOut: Boolean = false,
    val checkoutResult: CheckoutResult? = null,
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

    fun checkout() {
        val addressId = _state.value.selectedAddressId ?: return
        val code = _state.value.voucherCode.trim().takeIf { it.isNotEmpty() }
        viewModelScope.launch {
            _state.update { it.copy(isCheckingOut = true, error = null) }
            when (val result = buyRepo.checkout(addressId, code)) {
                is AppResult.Success -> _state.update {
                    it.copy(isCheckingOut = false, checkoutResult = result.data, voucherCode = "", cart = emptyList())
                }
                is AppResult.Failure -> _state.update { it.copy(isCheckingOut = false, error = result.error) }
            }
        }
    }

    fun dismissCheckoutResult() = _state.update { it.copy(checkoutResult = null, showCart = false) }

    fun clearError() = _state.update { it.copy(error = null) }

    /** Manual DI, matching SalesViewModel.Factory (§9). */
    class Factory(
        private val buyRepo: BuyRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = BuyViewModel(buyRepo, addressRepo) as T
    }
}
