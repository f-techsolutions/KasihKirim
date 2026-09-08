package com.ftechsolutions.kasihkirim.ui.muatanjual

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class MuatanJualUiState(
    val listings: List<MuatanJualListing> = emptyList(),
    val isLoading: Boolean = true,
    val error: AppError? = null,
)

class MuatanJualViewModel(private val repo: MuatanJualRepository) : ViewModel() {

    private val _state = MutableStateFlow(MuatanJualUiState())
    val state: StateFlow<MuatanJualUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = repo.listLots()) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, listings = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: MuatanJualRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = MuatanJualViewModel(repo) as T
    }
}
