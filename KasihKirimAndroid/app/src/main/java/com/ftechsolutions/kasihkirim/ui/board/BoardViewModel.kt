package com.ftechsolutions.kasihkirim.ui.board

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
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
            val nodeNames = (addressRepo.searchCommunities("") as? AppResult.Success)?.data
                ?.mapNotNull { c -> c.nodeId?.let { it to c.name } }
                ?.toMap()
                .orEmpty()
            when {
                boardResult is AppResult.Failure ->
                    _state.update { it.copy(isLoading = false, error = boardResult.error) }
                tripsResult is AppResult.Failure ->
                    _state.update { it.copy(isLoading = false, error = tripsResult.error) }
                boardResult is AppResult.Success && tripsResult is AppResult.Success ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            items = boardResult.data,
                            eligibleTrips = tripsResult.data.filter { t ->
                                t.status == TripStatus.ANNOUNCED || t.status == TripStatus.BOARDING
                            },
                            nodeNames = nodeNames,
                        )
                    }
            }
        }
    }

    fun acceptOffer(kirimId: String, tripId: String) {
        viewModelScope.launch {
            _state.update { it.copy(acceptingKirimId = kirimId, error = null) }
            when (val result = tripRepo.acceptOffer(tripId, kirimId)) {
                // The matched item leaves the board server-side (status != POSTED);
                // reload rather than guess at the new state locally.
                is AppResult.Success -> { load() }
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
