package com.ftechsolutions.kasihkirim.ui.deliveries

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.DeliveryTracking
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryTrackingRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class DeliveryTrackingUiState(
    val tracking: DeliveryTracking? = null,
    val isLoading: Boolean = true,
    val error: AppError? = null,
)

class DeliveryTrackingViewModel(
    private val repo: DeliveryTrackingRepository,
    private val deliveryId: String,
) : ViewModel() {

    private val _state = MutableStateFlow(DeliveryTrackingUiState())
    val state: StateFlow<DeliveryTrackingUiState> = _state.asStateFlow()

    init {
        refresh()
        // Realtime only signals that something changed (see
        // DeliveryTrackingRepository.observeLocationChanges' own doc) --
        // every actual value still comes from rpc_get_delivery_tracking, the
        // one place ST_Y/ST_X extraction happens.
        viewModelScope.launch {
            repo.observeLocationChanges(deliveryId).collect { refresh() }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            when (val result = repo.getTracking(deliveryId)) {
                is AppResult.Success -> _state.update { it.copy(tracking = result.data, isLoading = false, error = null) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val repo: DeliveryTrackingRepository,
        private val deliveryId: String,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = DeliveryTrackingViewModel(repo, deliveryId) as T
    }
}
