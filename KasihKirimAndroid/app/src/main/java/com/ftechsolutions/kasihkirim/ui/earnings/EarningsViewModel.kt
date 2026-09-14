package com.ftechsolutions.kasihkirim.ui.earnings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BankAccount
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.PayeeType
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class EarningsUiState(
    val isLoading: Boolean = false,
    val earnings: Earnings? = null,
    val bankAccounts: List<BankAccount> = emptyList(),
    val payouts: List<PayoutRequest> = emptyList(),
    /** True while rpc_add_bank_account or rpc_request_withdrawal is in
     *  flight -- there is only ever one such form open at a time, so a
     *  single flag is enough (unlike AdminViewModel's per-row decidingId). */
    val isSubmitting: Boolean = false,
    val error: AppError? = null,
)

class EarningsViewModel(private val repo: EarningsRepository) : ViewModel() {

    private val _state = MutableStateFlow(EarningsUiState())
    val state: StateFlow<EarningsUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val earnings = repo.myEarnings()
            val bankAccounts = repo.myBankAccounts()
            val payouts = repo.myPayouts()
            // Same shape as AdminViewModel's own load(): one failure is
            // reported, but whatever did load still renders.
            _state.update {
                it.copy(
                    isLoading = false,
                    earnings = (earnings as? AppResult.Success)?.data ?: it.earnings,
                    bankAccounts = (bankAccounts as? AppResult.Success)?.data ?: it.bankAccounts,
                    payouts = (payouts as? AppResult.Success)?.data ?: it.payouts,
                    error = listOf(earnings, bankAccounts, payouts)
                        .filterIsInstance<AppResult.Failure>()
                        .firstOrNull()?.error,
                )
            }
        }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    fun addBankAccount(bankCode: String, accountNo: String, holderName: String) {
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            when (val result = repo.addBankAccount(bankCode, accountNo, holderName)) {
                is AppResult.Success -> {
                    _state.update { it.copy(isSubmitting = false) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    fun requestWithdrawal(payeeType: PayeeType, bankAccountId: String, amountSen: Long) {
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            when (val result = repo.requestWithdrawal(payeeType, bankAccountId, amountSen)) {
                is AppResult.Success -> {
                    _state.update { it.copy(isSubmitting = false) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: EarningsRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = EarningsViewModel(repo) as T
    }
}
