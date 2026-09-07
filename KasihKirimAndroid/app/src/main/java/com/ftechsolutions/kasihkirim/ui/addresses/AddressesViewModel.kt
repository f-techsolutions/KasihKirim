package com.ftechsolutions.kasihkirim.ui.addresses

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** A Malaysian mobile number, +60 followed by 8-10 digits -- the exact shape
 *  public.addresses' CHECK constraint requires (DATABASE.md §4.4). This is a
 *  format check only, not a business rule: see VALIDATION_CONTRACT.md §4. */
private val PHONE_PATTERN = Regex("^\\+60[0-9]{8,10}$")

data class AddressFormState(
    val label: String = "",
    val recipientName: String = "",
    val recipientPhone: String = "",
    val landmarkNote: String = "",
    val selectedCommunity: Community? = null,
    val communityQuery: String = "",
    val communityResults: List<Community> = emptyList(),
) {
    val canSubmit: Boolean
        get() = label.isNotBlank() &&
            recipientName.isNotBlank() &&
            PHONE_PATTERN.matches(recipientPhone) &&
            landmarkNote.length in 3..500 &&
            selectedCommunity != null
}

data class AddressesUiState(
    val addresses: List<Address> = emptyList(),
    val isLoading: Boolean = true,
    val isSubmitting: Boolean = false,
    val error: AppError? = null,
    val form: AddressFormState = AddressFormState(),
)

class AddressesViewModel(private val repo: AddressRepository) : ViewModel() {

    private val _state = MutableStateFlow(AddressesUiState())
    val state: StateFlow<AddressesUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = repo.listAddresses()) {
                is AppResult.Success -> _state.update { it.copy(addresses = result.data, isLoading = false) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    fun onLabelChange(v: String) = updateForm { it.copy(label = v) }
    fun onRecipientNameChange(v: String) = updateForm { it.copy(recipientName = v) }
    fun onRecipientPhoneChange(v: String) = updateForm { it.copy(recipientPhone = v) }
    fun onLandmarkNoteChange(v: String) = updateForm { it.copy(landmarkNote = v) }

    fun onCommunityQueryChange(v: String) {
        updateForm { it.copy(communityQuery = v) }
        viewModelScope.launch {
            when (val result = repo.searchCommunities(v)) {
                is AppResult.Success -> updateForm { it.copy(communityResults = result.data) }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun onCommunitySelected(community: Community) =
        updateForm { it.copy(selectedCommunity = community, communityResults = emptyList(), communityQuery = community.name) }

    fun submit() {
        val form = _state.value.form
        if (!form.canSubmit) return
        val community = form.selectedCommunity ?: return
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            val draft = NewAddress(
                label = form.label,
                recipientName = form.recipientName,
                recipientPhone = form.recipientPhone,
                communityId = community.id,
                landmarkNote = form.landmarkNote,
            )
            when (val result = repo.createAddress(draft)) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        isSubmitting = false,
                        addresses = listOf(result.data) + it.addresses,
                        form = AddressFormState(),
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    fun setDefault(id: String) {
        viewModelScope.launch {
            when (val result = repo.setDefaultAddress(id)) {
                is AppResult.Success -> load()   // re-fetch: two rows changed server-side
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun delete(id: String) {
        viewModelScope.launch {
            when (val result = repo.deleteAddress(id)) {
                is AppResult.Success -> _state.update { it.copy(addresses = it.addresses.filterNot { a -> a.id == id }) }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    private inline fun updateForm(transform: (AddressFormState) -> AddressFormState) =
        _state.update { it.copy(form = transform(it.form)) }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: AddressRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AddressesViewModel(repo) as T
    }
}
