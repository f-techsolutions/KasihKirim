package com.ftechsolutions.kasihkirim.ui.promotions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BankAccount
import com.ftechsolutions.kasihkirim.domain.model.MyPromotion
import com.ftechsolutions.kasihkirim.domain.model.OpenedPromotion
import com.ftechsolutions.kasihkirim.domain.model.PayeeType
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import com.ftechsolutions.kasihkirim.domain.repository.PromotionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class PromotionsUiState(
    val isLoading: Boolean = true,
    val promotions: List<MyPromotion> = emptyList(),
    val availableSen: Sen = Sen.ZERO,
    val bankAccounts: List<BankAccount> = emptyList(),
    /** Only this promoter's own withdrawal requests -- rpc_my_payouts
     *  returns every payee role the caller holds (carrier/seller/promoter
     *  alike), filtered here to what this screen is actually about. */
    val payouts: List<PayoutRequest> = emptyList(),
    val redeemCode: String = "",
    val redeemResult: OpenedPromotion? = null,
    val isRedeeming: Boolean = false,
    val isSubmitting: Boolean = false,
    val error: AppError? = null,
)

/** Kongsi & Untung's own screen: redeem a shared code, see the promoter's
 *  own codes and earnings (rpc_my_promotions), and cash out through the
 *  same bank-account/withdrawal RPCs a carrier or seller already uses
 *  (EarningsRepository, PayeeType.PROMOTER) -- see PromotionRepository's
 *  own header comment for why no new payout methods were needed. */
class PromotionsViewModel(
    private val promotionRepo: PromotionRepository,
    private val earningsRepo: EarningsRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(PromotionsUiState())
    val state: StateFlow<PromotionsUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val mine = promotionRepo.myPromotions()
            val bankAccounts = earningsRepo.myBankAccounts()
            val payouts = earningsRepo.myPayouts()
            _state.update {
                it.copy(
                    isLoading = false,
                    promotions = (mine as? AppResult.Success)?.data?.promotions ?: it.promotions,
                    availableSen = (mine as? AppResult.Success)?.data?.availableSen ?: it.availableSen,
                    bankAccounts = (bankAccounts as? AppResult.Success)?.data ?: it.bankAccounts,
                    payouts = (payouts as? AppResult.Success)?.data?.filter { p -> p.payeeType == "promoter" }
                        ?: it.payouts,
                    error = listOf(mine, bankAccounts, payouts)
                        .filterIsInstance<AppResult.Failure>()
                        .firstOrNull()?.error,
                )
            }
        }
    }

    fun clearError() = _state.update { it.copy(error = null) }

    fun onRedeemCodeChange(code: String) = _state.update { it.copy(redeemCode = code, redeemResult = null) }

    fun redeemCode() {
        val code = _state.value.redeemCode.trim()
        if (code.isEmpty()) return
        viewModelScope.launch {
            _state.update { it.copy(isRedeeming = true, error = null) }
            when (val result = promotionRepo.openPromotion(code)) {
                is AppResult.Success -> _state.update { it.copy(isRedeeming = false, redeemResult = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isRedeeming = false, error = result.error) }
            }
        }
    }

    fun addBankAccount(bankCode: String, accountNo: String, holderName: String) {
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            when (val result = earningsRepo.addBankAccount(bankCode, accountNo, holderName)) {
                is AppResult.Success -> {
                    _state.update { it.copy(isSubmitting = false) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    fun requestWithdrawal(bankAccountId: String, amountSen: Long) {
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            when (val result = earningsRepo.requestWithdrawal(PayeeType.PROMOTER, bankAccountId, amountSen)) {
                is AppResult.Success -> {
                    _state.update { it.copy(isSubmitting = false) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching EarningsViewModel.Factory (§9). */
    class Factory(
        private val promotionRepo: PromotionRepository,
        private val earningsRepo: EarningsRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            PromotionsViewModel(promotionRepo, earningsRepo) as T
    }
}
