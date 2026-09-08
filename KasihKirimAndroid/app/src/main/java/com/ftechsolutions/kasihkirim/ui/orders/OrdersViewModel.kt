package com.ftechsolutions.kasihkirim.ui.orders

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class OrdersUiState(
    val orders: List<KirimSummary> = emptyList(),
    /** node_id -> a Community that happens to share it, best-effort display
     *  only -- ref.route_nodes itself isn't reachable from this client (same
     *  limitation Trips/Board already live with). */
    val nodeNames: Map<String, String> = emptyMap(),
    val isLoading: Boolean = true,
    val error: AppError? = null,
)

class OrdersViewModel(
    private val kirimRepo: KirimRepository,
    private val addressRepo: AddressRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(OrdersUiState())
    val state: StateFlow<OrdersUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val ordersResult = kirimRepo.listMyKirims()
            val nodeNames = (addressRepo.searchCommunities("") as? AppResult.Success)?.data
                ?.mapNotNull { c -> c.nodeId?.let { it to c.name } }
                ?.toMap()
                .orEmpty()
            when (ordersResult) {
                is AppResult.Success -> _state.update {
                    it.copy(isLoading = false, orders = ordersResult.data, nodeNames = nodeNames)
                }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = ordersResult.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val kirimRepo: KirimRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = OrdersViewModel(kirimRepo, addressRepo) as T
    }
}
