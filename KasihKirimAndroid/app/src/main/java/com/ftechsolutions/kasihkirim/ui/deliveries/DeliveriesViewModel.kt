package com.ftechsolutions.kasihkirim.ui.deliveries

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.DisputeCategory
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
    /** Non-null while the carrier's "report a problem" dialog is open for
     *  this DELIVERED delivery (rpc_open_carrier_dispute, 0039). */
    val openDisputeDeliveryId: String? = null,
    val disputeCategory: DisputeCategory = DisputeCategory.OTHER,
    val disputeDescription: String = "",
    /** Ids of deliveries the caller has already reviewed -- loaded alongside
     *  [deliveries] so a COMPLETED delivery already rated doesn't show the
     *  Rate button again. */
    val reviewedDeliveryIds: Set<String> = emptySet(),
    /** Non-null while the rating dialog is open for this COMPLETED delivery
     *  (rpc_submit_review, 0044). */
    val rateDeliveryId: String? = null,
    val ratingValue: Int = 5,
    val ratingComment: String = "",
)

data class PendingProof(val deliveryId: String, val leg: String, val event: String)

class DeliveriesViewModel(private val repo: DeliveryRepository) : ViewModel() {

    private val _state = MutableStateFlow(DeliveriesUiState())
    val state: StateFlow<DeliveriesUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val deliveries = repo.listMyDeliveries()
            val reviewed = repo.listMyReviewedDeliveryIds()
            // Same reasoning as AdminViewModel's own load(): one failure is
            // reported, but whatever did load still renders -- a broken
            // reviewed-ids read shouldn't hide the delivery list itself.
            _state.update {
                it.copy(
                    isLoading = false,
                    deliveries = (deliveries as? AppResult.Success)?.data ?: it.deliveries,
                    reviewedDeliveryIds = (reviewed as? AppResult.Success)?.data ?: it.reviewedDeliveryIds,
                    error = listOf(deliveries, reviewed)
                        .filterIsInstance<AppResult.Failure>()
                        .firstOrNull()?.error,
                )
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

    /** Opens the "report a problem" dialog for a DELIVERED delivery. */
    fun requestOpenDispute(deliveryId: String) {
        _state.update {
            it.copy(
                openDisputeDeliveryId = deliveryId, error = null,
                disputeCategory = DisputeCategory.OTHER, disputeDescription = "",
            )
        }
    }

    fun cancelOpenDispute() = _state.update { it.copy(openDisputeDeliveryId = null) }

    fun onDisputeCategorySelected(category: DisputeCategory) = _state.update { it.copy(disputeCategory = category) }
    fun onDisputeDescriptionChange(text: String) = _state.update { it.copy(disputeDescription = text) }

    /** rpc_open_carrier_dispute (0039). */
    fun submitDispute() {
        val deliveryId = _state.value.openDisputeDeliveryId ?: return
        val category = _state.value.disputeCategory
        val description = _state.value.disputeDescription.trim()
        viewModelScope.launch {
            _state.update { it.copy(transitioningId = deliveryId, openDisputeDeliveryId = null, error = null) }
            when (val result = repo.openDispute(deliveryId, category.wire, description)) {
                is AppResult.Success -> {
                    _state.update { it.copy(transitioningId = null) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(transitioningId = null, error = result.error) }
            }
        }
    }

    /** Opens the rating dialog for a COMPLETED delivery. */
    fun requestRate(deliveryId: String) {
        _state.update { it.copy(rateDeliveryId = deliveryId, error = null, ratingValue = 5, ratingComment = "") }
    }

    fun cancelRate() = _state.update { it.copy(rateDeliveryId = null) }

    fun onRatingValueChange(value: Int) = _state.update { it.copy(ratingValue = value) }
    fun onRatingCommentChange(text: String) = _state.update { it.copy(ratingComment = text) }

    /** rpc_submit_review (0044). Not routed through [decide]: a rated
     *  delivery never leaves [DeliveriesUiState.deliveries] the way a queue
     *  row leaves a review queue -- only [reviewedDeliveryIds] needs to
     *  reflect the change, so [load] (not a full reload elsewhere) is enough. */
    fun submitRating() {
        val deliveryId = _state.value.rateDeliveryId ?: return
        val rating = _state.value.ratingValue
        val comment = _state.value.ratingComment.trim().takeIf { it.isNotEmpty() }
        viewModelScope.launch {
            _state.update { it.copy(transitioningId = deliveryId, rateDeliveryId = null, error = null) }
            when (val result = repo.submitReview(deliveryId, rating, comment)) {
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
