package com.ftechsolutions.kasihkirim.ui.carrier

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierProfile
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewCarrier
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.CarrierRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The carrier application form -- rpc_apply_carrier's params. */
data class CarrierApplicationFormState(
    val communityQuery: String = "",
    val selectedCommunity: Community? = null,
    val communityResults: List<Community> = emptyList(),
) {
    val canSubmit: Boolean get() = selectedCommunity != null
}

data class CarrierApplicationUiState(
    val isLoading: Boolean = true,
    /** null once loaded means "never applied" -- see the empty-state screen. */
    val carrier: CarrierProfile? = null,
    val applicationForm: CarrierApplicationFormState = CarrierApplicationFormState(),
    val isSubmittingApplication: Boolean = false,
    val error: AppError? = null,
)

/** Onboarding only (0040_carrier_onboarding_and_verification.sql) -- mirrors
 *  SalesViewModel's own application section. Deliberately does not grow into
 *  a carrier dashboard the way SalesScreen did for sellers: once APPROVED,
 *  Board/Trips/Vehicles/Deliveries/Earnings (existing tabs) already cover
 *  everything a carrier does, so this screen has nothing further to add --
 *  ProfileScreen stops offering it once the role is held. */
class CarrierApplicationViewModel(
    private val carrierRepo: CarrierRepository,
    private val addressRepo: AddressRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(CarrierApplicationUiState())
    val state: StateFlow<CarrierApplicationUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = carrierRepo.getMyCarrierApplication()) {
                is AppResult.Success -> _state.update { it.copy(isLoading = false, carrier = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    fun onCommunityQueryChange(v: String) {
        updateApplicationForm { it.copy(communityQuery = v) }
        viewModelScope.launch {
            when (val result = addressRepo.searchCommunities(v)) {
                is AppResult.Success -> updateApplicationForm { it.copy(communityResults = result.data) }
                is AppResult.Failure -> Unit
            }
        }
    }

    fun onCommunitySelected(community: Community) = updateApplicationForm {
        it.copy(selectedCommunity = community, communityResults = emptyList(), communityQuery = community.name)
    }

    fun onCommunityCleared() = updateApplicationForm {
        it.copy(selectedCommunity = null, communityQuery = "", communityResults = emptyList())
    }

    fun submitApplication() {
        val form = _state.value.applicationForm
        val communityId = form.selectedCommunity?.id ?: return
        if (!form.canSubmit) return
        viewModelScope.launch {
            _state.update { it.copy(isSubmittingApplication = true, error = null) }
            when (val result = carrierRepo.applyCarrier(NewCarrier(homeCommunityId = communityId))) {
                is AppResult.Success -> _state.update {
                    it.copy(isSubmittingApplication = false, carrier = result.data, isLoading = false)
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmittingApplication = false, error = result.error) }
            }
        }
    }

    private inline fun updateApplicationForm(
        transform: (CarrierApplicationFormState) -> CarrierApplicationFormState,
    ) = _state.update { it.copy(applicationForm = transform(it.applicationForm)) }

    /** Manual DI, matching SalesViewModel.Factory (§9). */
    class Factory(
        private val carrierRepo: CarrierRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            CarrierApplicationViewModel(carrierRepo, addressRepo) as T
    }
}
