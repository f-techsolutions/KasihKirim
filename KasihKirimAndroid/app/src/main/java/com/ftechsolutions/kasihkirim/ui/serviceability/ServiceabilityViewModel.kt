package com.ftechsolutions.kasihkirim.ui.serviceability

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class ServiceabilityFormState(
    val originQuery: String = "",
    val originResults: List<Community> = emptyList(),
    val selectedOrigin: Community? = null,
    val destQuery: String = "",
    val destResults: List<Community> = emptyList(),
    val selectedDest: Community? = null,
) {
    // A community without a resolved route node can't be sent to the RPC --
    // ref.route_nodes isn't reachable any other way for this client.
    val canCheck: Boolean
        get() = selectedOrigin?.nodeId != null && selectedDest?.nodeId != null
}

data class ServiceabilityUiState(
    val form: ServiceabilityFormState = ServiceabilityFormState(),
    val isChecking: Boolean = false,
    val result: Serviceability? = null,
    val error: AppError? = null,
)

class ServiceabilityViewModel(private val repo: AddressRepository) : ViewModel() {

    private val _state = MutableStateFlow(ServiceabilityUiState())
    val state: StateFlow<ServiceabilityUiState> = _state.asStateFlow()

    fun onOriginQueryChange(v: String) {
        updateForm { it.copy(originQuery = v) }
        viewModelScope.launch {
            when (val result = repo.searchCommunities(v)) {
                is AppResult.Success -> updateForm { it.copy(originResults = result.data) }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun onDestQueryChange(v: String) {
        updateForm { it.copy(destQuery = v) }
        viewModelScope.launch {
            when (val result = repo.searchCommunities(v)) {
                is AppResult.Success -> updateForm { it.copy(destResults = result.data) }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun onOriginSelected(community: Community) =
        updateForm { it.copy(selectedOrigin = community, originResults = emptyList(), originQuery = community.name) }

    fun onDestSelected(community: Community) =
        updateForm { it.copy(selectedDest = community, destResults = emptyList(), destQuery = community.name) }

    fun onOriginCleared() =
        updateForm { it.copy(selectedOrigin = null, originQuery = "", originResults = emptyList()) }

    fun onDestCleared() =
        updateForm { it.copy(selectedDest = null, destQuery = "", destResults = emptyList()) }

    fun check() {
        val form = _state.value.form
        val originId = form.selectedOrigin?.nodeId ?: return
        val destId = form.selectedDest?.nodeId ?: return
        viewModelScope.launch {
            _state.update { it.copy(isChecking = true, error = null, result = null) }
            when (val result = repo.checkServiceability(originId, destId)) {
                is AppResult.Success -> _state.update { it.copy(isChecking = false, result = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isChecking = false, error = result.error) }
            }
        }
    }

    private inline fun updateForm(transform: (ServiceabilityFormState) -> ServiceabilityFormState) =
        _state.update { it.copy(form = transform(it.form)) }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: AddressRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = ServiceabilityViewModel(repo) as T
    }
}
