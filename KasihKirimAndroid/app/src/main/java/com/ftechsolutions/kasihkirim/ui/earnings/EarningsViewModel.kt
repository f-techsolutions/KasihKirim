package com.ftechsolutions.kasihkirim.ui.earnings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class EarningsUiState(
    val isLoading: Boolean = false,
    val earnings: Earnings? = null,
    val error: AppError? = null,
)

class EarningsViewModel(private val repo: EarningsRepository) : ViewModel() {

    private val _state = MutableStateFlow(EarningsUiState())
    val state: StateFlow<EarningsUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = repo.myEarnings()) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, earnings = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: EarningsRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = EarningsViewModel(repo) as T
    }
}
