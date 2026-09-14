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
    /** Non-null while the photo-capture flow for a requires_proof=true
     *  transition is open, so the screen knows which delivery/leg/event a
     *  captured photo belongs to once the camera returns. */
    val pendingProof: PendingProof? = null,
    /** Non-null while the "record purchase" amount dialog is open for this
     *  BELI delivery. */
    val recordPurchaseDeliveryId: String? = null,
)

data class PendingProof(val deliveryId: String, val leg: String, val event: String)

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

    /** Opens the photo-capture step for a requires_proof=true transition;
     *  the screen launches the camera once this is set. */
    fun requestProof(deliveryId: String, leg: String, event: String) {
        _state.update { it.copy(pendingProof = PendingProof(deliveryId, leg, event), error = null) }
    }

    /** The camera launcher returned with no photo (user backed out) or a
     *  capture failure -- close the flow without calling the backend. */
    fun cancelProof() {
        _state.update { it.copy(pendingProof = null) }
    }

    /** A photo was captured for the open [DeliveriesUiState.pendingProof] --
     *  upload it, submit the proof, then advance the delivery's status. */
    fun submitProof(photoBytes: ByteArray) {
        val pending = _state.value.pendingProof ?: return
        viewModelScope.launch {
            _state.update { it.copy(transitioningId = pending.deliveryId, pendingProof = null, error = null) }
            when (
                val result = repo.submitProofAndTransition(
                    pending.deliveryId, pending.leg, pending.event, photoBytes,
                )
            ) {
                is AppResult.Success -> {
                    _state.update { it.copy(transitioningId = null) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(transitioningId = null, error = result.error) }
            }
        }
    }

    /** Opens the amount-entry dialog for recording a BELI purchase. */
    fun requestRecordPurchase(deliveryId: String) {
        _state.update { it.copy(recordPurchaseDeliveryId = deliveryId, error = null) }
    }

    fun cancelRecordPurchase() {
        _state.update { it.copy(recordPurchaseDeliveryId = null) }
    }

    /** The carrier confirmed how much they actually spent -- record it and
     *  advance the delivery out of PROCURING. */
    fun recordPurchase(actualGoodsSen: Long) {
        val deliveryId = _state.value.recordPurchaseDeliveryId ?: return
        viewModelScope.launch {
            _state.update { it.copy(transitioningId = deliveryId, recordPurchaseDeliveryId = null, error = null) }
            when (val result = repo.recordPurchase(deliveryId, actualGoodsSen)) {
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
