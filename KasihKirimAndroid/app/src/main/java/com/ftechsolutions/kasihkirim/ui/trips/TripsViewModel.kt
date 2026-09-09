package com.ftechsolutions.kasihkirim.ui.trips

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

data class TripFormState(
    val selectedVehicle: Vehicle? = null,
    val originQuery: String = "",
    val originResults: List<Community> = emptyList(),
    val selectedOrigin: Community? = null,
    val destQuery: String = "",
    val destResults: List<Community> = emptyList(),
    val selectedDest: Community? = null,
    /** Epoch millis at UTC midnight of the chosen date, the shape Compose's
     *  DatePicker returns -- null means not yet chosen. */
    val departDateMillis: Long? = null,
    val departHour: Int = 8,
    val departMinute: Int = 0,
) {
    val canSubmit: Boolean
        get() = selectedVehicle != null &&
            selectedOrigin?.nodeId != null &&
            selectedDest?.nodeId != null &&
            departDateMillis != null

    private fun departAtIsoOrNull(): String? {
        val dateMillis = departDateMillis ?: return null
        val date = Instant.ofEpochMilli(dateMillis).atZone(ZoneOffset.UTC).toLocalDate()
        return date.atTime(departHour, departMinute).atZone(ZoneId.systemDefault()).toInstant().toString()
    }

    fun toDraftOrNull(): NewTripDraft? {
        val vehicle = selectedVehicle ?: return null
        val originId = selectedOrigin?.nodeId ?: return null
        val destId = selectedDest?.nodeId ?: return null
        val departAt = departAtIsoOrNull() ?: return null
        return NewTripDraft(vehicleId = vehicle.id, originNodeId = originId, destNodeId = destId, departAtIso = departAt)
    }
}

data class TripsUiState(
    val trips: List<Trip> = emptyList(),
    val vehicles: List<Vehicle> = emptyList(),
    /** node_id -> a Community that happens to share it, best-effort display
     *  only -- ref.route_nodes itself isn't reachable from this client
     *  (same limitation Serviceability/Kirim already live with). */
    val nodeNames: Map<String, String> = emptyMap(),
    val isLoading: Boolean = true,
    val isSubmitting: Boolean = false,
    val error: AppError? = null,
    val form: TripFormState = TripFormState(),
)

class TripsViewModel(
    private val tripRepo: TripRepository,
    private val vehicleRepo: VehicleRepository,
    private val addressRepo: AddressRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(TripsUiState())
    val state: StateFlow<TripsUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val tripsResult = tripRepo.listMyTrips()
            val vehiclesResult = vehicleRepo.listVehicles()
            val nodeNames = (addressRepo.searchCommunities("") as? AppResult.Success)?.data
                ?.mapNotNull { c -> c.nodeId?.let { it to c.name } }
                ?.toMap()
                .orEmpty()
            when {
                tripsResult is AppResult.Failure ->
                    _state.update { it.copy(isLoading = false, error = tripsResult.error) }
                vehiclesResult is AppResult.Failure ->
                    _state.update { it.copy(isLoading = false, error = vehiclesResult.error) }
                tripsResult is AppResult.Success && vehiclesResult is AppResult.Success ->
                    _state.update {
                        it.copy(
                            isLoading = false,
                            trips = tripsResult.data,
                            vehicles = vehiclesResult.data.filter { v -> v.isActive },
                            nodeNames = nodeNames,
                        )
                    }
            }
        }
    }

    fun onVehicleSelected(vehicle: Vehicle) = updateForm { it.copy(selectedVehicle = vehicle) }

    fun onOriginQueryChange(v: String) {
        updateForm { it.copy(originQuery = v) }
        searchCommunities(v) { results -> updateForm { it.copy(originResults = results) } }
    }

    fun onDestQueryChange(v: String) {
        updateForm { it.copy(destQuery = v) }
        searchCommunities(v) { results -> updateForm { it.copy(destResults = results) } }
    }

    fun onOriginSelected(community: Community) =
        updateForm { it.copy(selectedOrigin = community, originResults = emptyList(), originQuery = community.name) }

    fun onDestSelected(community: Community) =
        updateForm { it.copy(selectedDest = community, destResults = emptyList(), destQuery = community.name) }

    fun onOriginCleared() =
        updateForm { it.copy(selectedOrigin = null, originQuery = "", originResults = emptyList()) }

    fun onDestCleared() =
        updateForm { it.copy(selectedDest = null, destQuery = "", destResults = emptyList()) }

    fun onDepartDateChange(millis: Long?) = updateForm { it.copy(departDateMillis = millis) }
    fun onDepartTimeChange(hour: Int, minute: Int) = updateForm { it.copy(departHour = hour, departMinute = minute) }

    private fun searchCommunities(query: String, onResult: (List<Community>) -> Unit) {
        viewModelScope.launch {
            when (val result = addressRepo.searchCommunities(query)) {
                is AppResult.Success -> onResult(result.data)
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun createTrip() {
        val draft = _state.value.form.toDraftOrNull() ?: return
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            when (val result = tripRepo.createTrip(draft)) {
                is AppResult.Success -> _state.update {
                    it.copy(isSubmitting = false, trips = listOf(result.data) + it.trips, form = TripFormState())
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    private inline fun updateForm(transform: (TripFormState) -> TripFormState) =
        _state.update { it.copy(form = transform(it.form)) }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val tripRepo: TripRepository,
        private val vehicleRepo: VehicleRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            TripsViewModel(tripRepo, vehicleRepo, addressRepo) as T
    }
}
