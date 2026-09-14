package com.ftechsolutions.kasihkirim.ui.admin

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AccountStatus
import com.ftechsolutions.kasihkirim.domain.model.AdminAccount
import com.ftechsolutions.kasihkirim.domain.model.AdminPayout
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

enum class AdminQueue { SELLERS, CARRIERS, PRODUCTS, DISPUTES, ACCOUNTS, PAYOUTS }

data class AdminUiState(
    val isLoading: Boolean = true,
    val queue: AdminQueue = AdminQueue.SELLERS,
    val sellers: List<SellerApplication> = emptyList(),
    val carriers: List<CarrierApplication> = emptyList(),
    val products: List<ProductReview> = emptyList(),
    val disputes: List<Dispute> = emptyList(),
    val payouts: List<AdminPayout> = emptyList(),
    /** Not a queue loaded by [load] -- populated only once [searchAccounts]
     *  runs, since an empty query intentionally returns nothing. */
    val accountQuery: String = "",
    val accounts: List<AdminAccount> = emptyList(),
    val isSearchingAccounts: Boolean = false,
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
            val payouts = repo.listPayouts()
            // One failure is reported, but whatever did load still renders --
            // a broken dispute read shouldn't hide a seller waiting on approval.
            _state.update {
                it.copy(
                    isLoading = false,
                    sellers = (sellers as? AppResult.Success)?.data ?: it.sellers,
                    carriers = (carriers as? AppResult.Success)?.data ?: it.carriers,
                    products = (products as? AppResult.Success)?.data ?: it.products,
                    disputes = (disputes as? AppResult.Success)?.data ?: it.disputes,
                    payouts = (payouts as? AppResult.Success)?.data ?: it.payouts,
                    error = listOf(sellers, carriers, products, disputes, payouts)
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

    fun onAccountQueryChange(query: String) = _state.update { it.copy(accountQuery = query) }

    /** Not part of [load] -- runs only when the admin actually searches, and
     *  an empty query is refused client-side same as the repository refuses
     *  it server-side (the whole user base is never an acceptable result). */
    fun searchAccounts() {
        val query = _state.value.accountQuery
        if (query.isBlank()) {
            _state.update { it.copy(accounts = emptyList()) }
            return
        }
        viewModelScope.launch {
            _state.update { it.copy(isSearchingAccounts = true, error = null) }
            when (val result = repo.searchAccounts(query)) {
                is AppResult.Success ->
                    _state.update { it.copy(isSearchingAccounts = false, accounts = result.data) }
                is AppResult.Failure ->
                    _state.update { it.copy(isSearchingAccounts = false, error = result.error) }
            }
        }
    }

    /** Not routed through [decide]: accounts are search results, not a
     *  shrinking queue, so success re-runs the same search instead of
     *  reloading the four review queues. */
    fun setAccountStatus(userId: String, status: AccountStatus, reason: String? = null) {
        viewModelScope.launch {
            _state.update { it.copy(decidingId = userId, error = null) }
            when (val result = repo.setAccountStatus(userId, status, reason)) {
                is AppResult.Success -> {
                    _state.update { it.copy(decidingId = null) }
                    searchAccounts()
                }
                is AppResult.Failure ->
                    _state.update { it.copy(decidingId = null, error = result.error) }
            }
        }
    }

    /** First look: REQUESTED -> UNDER_REVIEW or REJECTED. */
    fun reviewPayout(payoutId: String, approve: Boolean, reason: String? = null) {
        decide(payoutId) { repo.reviewPayout(payoutId, approve, reason) }
    }

    /** Second look, by someone else: UNDER_REVIEW -> APPROVED or REJECTED.
     *  The server refuses the same admin who reviewed it -- this call can
     *  surface that as an ordinary error, same as any other rejection. */
    fun approvePayout(payoutId: String, approve: Boolean, reason: String? = null) {
        decide(payoutId) { repo.approvePayout(payoutId, approve, reason) }
    }

    /** The only step that posts to the ledger -- see AdminRepository's own
     *  doc comment. providerRef is a stub reference, never a real transfer. */
    fun markPayoutPaid(payoutId: String, providerRef: String? = null) {
        decide(payoutId) { repo.markPayoutPaid(payoutId, providerRef) }
    }

    fun markPayoutFailed(payoutId: String, reason: String) {
        decide(payoutId) { repo.markPayoutFailed(payoutId, reason) }
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
