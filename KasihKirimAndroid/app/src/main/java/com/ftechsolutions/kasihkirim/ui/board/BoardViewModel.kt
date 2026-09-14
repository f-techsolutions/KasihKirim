package com.ftechsolutions.kasihkirim.ui.board

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CapacityInvite
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class BoardUiState(
    val items: List<KirimSummary> = emptyList(),
    /** Trips the caller could accept an offer onto (ANNOUNCED/BOARDING),
     *  empty for a non-carrier -- listMyTrips is never called for one. */
    val eligibleTrips: List<Trip> = emptyList(),
    val nodeNames: Map<String, String> = emptyMap(),
    val isLoading: Boolean = true,
    /** The Kirim currently being accepted, if any -- disables its own button
     *  only, not the whole board. */
    val acceptingKirimId: String? = null,
    /** Ajak Kirim (0006_carrier_commerce.sql) invites addressed to the
     *  caller -- their own community, a direct target, or (for a carrier)
     *  one they sent. */
    val invites: List<CapacityInvite> = emptyList(),
    val respondedInviteIds: Set<String> = emptySet(),
    val respondingInviteId: String? = null,
    val error: AppError? = null,
)

class BoardViewModel(
    private val kirimRepo: KirimRepository,
    private val tripRepo: TripRepository,
    private val addressRepo: AddressRepository,
    private val isCarrier: Boolean,
) : ViewModel() {

    private val _state = MutableStateFlow(BoardUiState())
    val state: StateFlow<BoardUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val boardResult = kirimRepo.listBoard()
            val tripsResult = if (isCarrier) tripRepo.listMyTrips() else AppResult.Success(emptyList())
            val invitesResult = kirimRepo.listMyInvites()
            val nodeNames = (addressRepo.searchCommunities("") as? AppResult.Success)?.data
                ?.mapNotNull { c -> c.nodeId?.let { it to c.name } }
                ?.toMap()
                .orEmpty()
            when (boardResult) {
                is AppResult.Failure ->
                    _state.update { it.copy(isLoading = false, error = boardResult.error) }
                is AppResult.Success ->
                    // Found on-device: a tripsResult failure (e.g. a carrier
                    // whose 'carrier' role is granted but has no
                    // public.carriers row yet, so requireCarrierId() throws
                    // NOT_A_CARRIER) used to wipe out a perfectly successful
                    // board load and show a bare error instead -- a carrier
                    // could see zero board listings for a reason entirely
                    // unrelated to the board itself. eligibleTrips only
                    // gates the accept-offer UI on each card, so a failure to
                    // load "my trips" should leave it empty, never block the
                    // board the same way a failed invites load already
                    // doesn't (see invites below).
                    _state.update {
                        it.copy(
                            isLoading = false,
                            items = boardResult.data,
                            eligibleTrips = (tripsResult as? AppResult.Success)?.data
                                ?.filter { t -> t.status == TripStatus.ANNOUNCED || t.status == TripStatus.BOARDING }
                                ?: emptyList(),
                            nodeNames = nodeNames,
                            invites = (invitesResult as? AppResult.Success)?.data ?: it.invites,
                        )
                    }
            }
        }
    }

    fun respondToInvite(inviteId: String) {
        if (_state.value.respondingInviteId != null) return
        viewModelScope.launch {
            _state.update { it.copy(respondingInviteId = inviteId, error = null) }
            when (val result = kirimRepo.respondToInvite(inviteId)) {
                is AppResult.Success -> _state.update {
                    it.copy(respondingInviteId = null, respondedInviteIds = it.respondedInviteIds + inviteId)
                }
                is AppResult.Failure -> _state.update { it.copy(respondingInviteId = null, error = result.error) }
            }
        }
    }

    fun acceptOffer(kirimId: String, tripId: String) {
        viewModelScope.launch {
            _state.update { it.copy(acceptingKirimId = kirimId, error = null) }
            when (val result = tripRepo.acceptOffer(tripId, kirimId)) {
                // The matched item leaves the board server-side (status != POSTED);
                // reload rather than guess at the new state locally.
                is AppResult.Success -> {
                    _state.update { it.copy(acceptingKirimId = null) }
                    load()
                }
                is AppResult.Failure -> _state.update { it.copy(acceptingKirimId = null, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val kirimRepo: KirimRepository,
        private val tripRepo: TripRepository,
        private val addressRepo: AddressRepository,
        private val isCarrier: Boolean,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            BoardViewModel(kirimRepo, tripRepo, addressRepo, isCarrier) as T
    }
}
