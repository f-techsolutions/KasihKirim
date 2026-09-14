package com.ftechsolutions.kasihkirim.ui.buy

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.DeliveryStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.DisputeCategory
import com.ftechsolutions.kasihkirim.domain.model.PaymentStatusInfo
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class BuyOrdersUiState(
    val isLoading: Boolean = true,
    val orders: List<BuyOrder> = emptyList(),
    val selectedOrder: BuyOrder? = null,
    val isLoadingDetail: Boolean = false,
    val paymentStatus: PaymentStatusInfo? = null,
    val deliveryStatus: DeliveryStatusInfo? = null,
    val isLoadingDeliveryStatus: Boolean = false,
    /** A hosted Billplz page to open in a Custom Tab -- one-shot, consumed
     *  by BuyOrdersScreen's LaunchedEffect the same way BuyScreen's own
     *  checkout flow consumes it (see BuyViewModel.onPaymentUrlLaunched). */
    val pendingPaymentUrl: String? = null,
    val isPreparingPayment: Boolean = false,
    val showDisputeForm: Boolean = false,
    val disputeCategory: DisputeCategory = DisputeCategory.OTHER,
    val disputeDescription: String = "",
    val isFilingDispute: Boolean = false,
    val disputeSubmitted: Boolean = false,
    val error: AppError? = null,
)

/** The marketplace order-tracking + dispute-filing list this order-status
 *  poll and rpc_open_dispute (0034/0028) plug into -- separate from
 *  BuyViewModel, which already owns browse/cart/checkout, the same way
 *  OrdersViewModel is its own screen rather than folded into SendScreen's. */
class BuyOrdersViewModel(private val buyRepo: BuyRepository) : ViewModel() {

    private val _state = MutableStateFlow(BuyOrdersUiState())
    val state: StateFlow<BuyOrdersUiState> = _state.asStateFlow()

    init {
        loadOrders()
    }

    fun loadOrders() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = buyRepo.listMyOrders()) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, orders = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    fun selectOrder(order: BuyOrder) {
        _state.update {
            it.copy(
                selectedOrder = order, paymentStatus = null, deliveryStatus = null, showDisputeForm = false,
                disputeSubmitted = false, disputeDescription = "", disputeCategory = DisputeCategory.OTHER,
            )
        }
        if (order.paymentMethod != null && order.paymentMethod != "COD") {
            refreshPaymentStatus(order.id)
        }
        loadDeliveryStatus(order.id)
    }

    fun dismissOrderDetail() = _state.update { it.copy(selectedOrder = null, deliveryStatus = null) }

    fun loadDeliveryStatus(orderId: String) {
        viewModelScope.launch {
            _state.update { it.copy(isLoadingDeliveryStatus = true) }
            when (val result = buyRepo.getDeliveryStatus(orderId)) {
                is AppResult.Success -> _state.update { it.copy(isLoadingDeliveryStatus = false, deliveryStatus = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoadingDeliveryStatus = false, error = result.error) }
            }
        }
    }

    fun refreshPaymentStatus(orderId: String) {
        viewModelScope.launch {
            _state.update { it.copy(isLoadingDetail = true) }
            when (val result = buyRepo.getPaymentStatus(orderId)) {
                is AppResult.Success -> _state.update { it.copy(isLoadingDetail = false, paymentStatus = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoadingDetail = false, error = result.error) }
            }
        }
    }

    fun payNow(orderId: String) {
        viewModelScope.launch {
            _state.update { it.copy(isPreparingPayment = true, error = null) }
            when (val result = buyRepo.createPaymentIntent(orderId)) {
                is AppResult.Success ->
                    _state.update { it.copy(isPreparingPayment = false, pendingPaymentUrl = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isPreparingPayment = false, error = result.error) }
            }
        }
    }

    fun onPaymentUrlLaunched() = _state.update { it.copy(pendingPaymentUrl = null) }

    fun openDisputeForm() = _state.update { it.copy(showDisputeForm = true) }

    fun dismissDisputeForm() = _state.update { it.copy(showDisputeForm = false) }

    fun onDisputeCategorySelected(category: DisputeCategory) = _state.update { it.copy(disputeCategory = category) }

    fun onDisputeDescriptionChange(text: String) = _state.update { it.copy(disputeDescription = text) }

    fun submitDispute() {
        val orderId = _state.value.selectedOrder?.id ?: return
        val category = _state.value.disputeCategory
        val description = _state.value.disputeDescription.trim()
        viewModelScope.launch {
            _state.update { it.copy(isFilingDispute = true, error = null) }
            when (val result = buyRepo.fileDispute(orderId, category.wire, description)) {
                is AppResult.Success -> _state.update {
                    it.copy(isFilingDispute = false, showDisputeForm = false, disputeSubmitted = true)
                }
                is AppResult.Failure -> _state.update { it.copy(isFilingDispute = false, error = result.error) }
            }
        }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    /** Manual DI, matching BuyViewModel.Factory (§9). */
    class Factory(private val buyRepo: BuyRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = BuyOrdersViewModel(buyRepo) as T
    }
}
