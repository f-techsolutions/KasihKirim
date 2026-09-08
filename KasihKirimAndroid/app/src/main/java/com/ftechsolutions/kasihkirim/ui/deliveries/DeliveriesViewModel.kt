package com.ftechsolutions.kasihkirim.ui.deliveries

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class DeliveriesUiState(
    val deliveries: List<Delivery> = emptyList(),
    val isLoading: Boolean = true,
    /** The delivery currently mid-transition, if any -- disables its own
     *  buttons only, not the whole list. */
    val transitioningId: String? = null,
    val error: AppError? = null,
)

class DeliveriesViewModel(private val repo: DeliveryRepository) : ViewModel() {

    private val _state = MutableStateFlow(DeliveriesUiState())
    val state: StateFlow<DeliveriesUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = repo.listMyDeliveries()) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, deliveries = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    fun transition(deliveryId: String, event: String) {
        viewModelScope.launch {
            _state.update { it.copy(transitioningId = deliveryId, error = null) }
            when (val result = repo.transition(deliveryId, event)) {
                is AppResult.Success -> {
                    _state.update { it.copy(transitioningId = null) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(transitioningId = null, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: DeliveryRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = DeliveriesViewModel(repo) as T
    }
}
