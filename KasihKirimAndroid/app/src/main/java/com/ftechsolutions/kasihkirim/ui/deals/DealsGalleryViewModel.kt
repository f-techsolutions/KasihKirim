package com.ftechsolutions.kasihkirim.ui.deals

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.DealCampaign
import com.ftechsolutions.kasihkirim.domain.repository.DealsRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class DealsGalleryUiState(
    val isLoading: Boolean = true,
    val deals: List<DealCampaign> = emptyList(),
    val error: AppError? = null,
)

class DealsGalleryViewModel(private val dealsRepo: DealsRepository) : ViewModel() {

    private val _state = MutableStateFlow(DealsGalleryUiState())
    val state: StateFlow<DealsGalleryUiState> = _state.asStateFlow()

    init {
        load()
    }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = dealsRepo.listActiveDeals()) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, deals = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching ProfileViewModel.Factory (§9). */
    class Factory(private val dealsRepo: DealsRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = DealsGalleryViewModel(dealsRepo) as T
    }
}
