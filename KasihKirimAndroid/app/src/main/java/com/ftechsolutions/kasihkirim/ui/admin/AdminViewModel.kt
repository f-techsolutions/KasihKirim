package com.ftechsolutions.kasihkirim.ui.admin

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierApplication
import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
import com.ftechsolutions.kasihkirim.domain.model.ProductReview
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.SellerApplication
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.repository.AdminRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

enum class AdminQueue { SELLERS, CARRIERS, PRODUCTS, DISPUTES }

data class AdminUiState(
    val isLoading: Boolean = true,
    val queue: AdminQueue = AdminQueue.SELLERS,
    val sellers: List<SellerApplication> = emptyList(),
    val carriers: List<CarrierApplication> = emptyList(),
    val products: List<ProductReview> = emptyList(),
    val disputes: List<Dispute> = emptyList(),
    /** The row currently being decided, so only its own buttons disable. */
    val decidingId: String? = null,
    /** Set after an approval that grants a role, since the grant only reaches
     *  the applicant when their token is next minted. */
    val notice: AdminNotice? = null,
    val error: AppError? = null,
)

enum class AdminNotice { SELLER_APPROVED_MUST_RESIGN, CARRIER_APPROVED_MUST_RESIGN }

class AdminViewModel(private val repo: AdminRepository) : ViewModel() {

    private val _state = MutableStateFlow(AdminUiState())
    val state: StateFlow<AdminUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val sellers = repo.listSellerApplications()
            val carriers = repo.listCarrierApplications()
            val products = repo.listProductReviews()
            val disputes = repo.listOpenDisputes()
            // One failure is reported, but whatever did load still renders --
            // a broken dispute read shouldn't hide a seller waiting on approval.
            _state.update {
                it.copy(
                    isLoading = false,
                    sellers = (sellers as? AppResult.Success)?.data ?: it.sellers,
                    carriers = (carriers as? AppResult.Success)?.data ?: it.carriers,
                    products = (products as? AppResult.Success)?.data ?: it.products,
                    disputes = (disputes as? AppResult.Success)?.data ?: it.disputes,
                    error = listOf(sellers, carriers, products, disputes)
                        .filterIsInstance<AppResult.Failure>()
                        .firstOrNull()?.error,
                )
            }
        }
    }

    fun selectQueue(queue: AdminQueue) = _state.update { it.copy(queue = queue, notice = null) }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    fun decideSeller(sellerId: String, status: SellerStatus, reason: String? = null) {
        decide(sellerId) {
            val result = repo.setSellerStatus(sellerId, status, reason)
            if (result is AppResult.Success && status == SellerStatus.APPROVED) {
                _state.update { it.copy(notice = AdminNotice.SELLER_APPROVED_MUST_RESIGN) }
            }
            result
        }
    }

    fun decideCarrier(carrierId: String, status: SellerStatus, reason: String? = null) {
        decide(carrierId) {
            val result = repo.setCarrierStatus(carrierId, status, reason)
            if (result is AppResult.Success && status == SellerStatus.APPROVED) {
                _state.update { it.copy(notice = AdminNotice.CARRIER_APPROVED_MUST_RESIGN) }
            }
            result
        }
    }

    fun decideProduct(productId: String, status: ProductStatus, rejectionReason: String? = null) {
        decide(productId) { repo.setProductStatus(productId, status, rejectionReason) }
    }

    fun resolveDispute(
        disputeId: String,
        status: DisputeStatus,
        note: String? = null,
        refundSen: Long = 0,
    ) {
        decide(disputeId) { repo.resolveDispute(disputeId, status, note, refundSen) }
    }

    /** Every decision follows the same shape: mark the row busy, call the
     *  server, then reload from the server rather than guessing the new queue
     *  locally -- the row may have left the queue entirely. */
    private fun decide(rowId: String, call: suspend () -> AppResult<Unit>) {
        viewModelScope.launch {
            _state.update { it.copy(decidingId = rowId, error = null) }
            when (val result = call()) {
                is AppResult.Success -> {
                    _state.update { it.copy(decidingId = null) }
                    load()
                }
                is AppResult.Failure ->
                    _state.update { it.copy(decidingId = null, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: AdminRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AdminViewModel(repo) as T
    }
}
