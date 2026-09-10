package com.ftechsolutions.kasihkirim.ui.profile

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Badge
import com.ftechsolutions.kasihkirim.domain.repository.BadgeRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ProfileUiState(
    val badges: List<Badge> = emptyList(),
    val isLoadingBadges: Boolean = true,
)

class ProfileViewModel(private val badgeRepo: BadgeRepository) : ViewModel() {

    private val _state = MutableStateFlow(ProfileUiState())
    val state: StateFlow<ProfileUiState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            when (val result = badgeRepo.listMyBadges()) {
                is AppResult.Success -> _state.update { it.copy(isLoadingBadges = false, badges = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoadingBadges = false) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val badgeRepo: BadgeRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = ProfileViewModel(badgeRepo) as T
    }
}
