package com.ftechsolutions.kasihkirim.ui.vehicles

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.NewVehicle
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.model.VehicleType
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** Presentation-only bounds mirroring the CHECK constraints on public.vehicles
 *  (0001_schema.sql) -- not a business rule, see VALIDATION_CONTRACT.md §4. */
data class VehicleFormState(
    val vehicleType: VehicleType = VehicleType.MOTORCYCLE,
    val plateNo: String = "",
    val makeModel: String = "",
    val capacityWeightGrams: String = "",
    val capacityVolumeCm3: String = "",
    val capacityParcels: String = "",
    /** Null means "new vehicle"; set means submit() updates this id instead
     *  of creating a new row. */
    val editingId: String? = null,
) {
    val isEditing: Boolean get() = editingId != null

    val canSubmit: Boolean
        get() = (capacityWeightGrams.toIntOrNull() ?: 0) > 0 &&
            (capacityVolumeCm3.toIntOrNull() ?: 0) > 0 &&
            (capacityParcels.toIntOrNull() ?: 0) > 0

    fun toDraftOrNull(): NewVehicle? {
        val weight = capacityWeightGrams.toIntOrNull()?.takeIf { it > 0 } ?: return null
        val volume = capacityVolumeCm3.toIntOrNull()?.takeIf { it > 0 } ?: return null
        val parcels = capacityParcels.toIntOrNull()?.takeIf { it > 0 } ?: return null
        return NewVehicle(
            vehicleType = vehicleType,
            plateNo = plateNo.trim().takeIf { it.isNotEmpty() },
            makeModel = makeModel.trim().takeIf { it.isNotEmpty() },
            capacityWeightGrams = weight,
            capacityVolumeCm3 = volume,
            capacityParcels = parcels,
        )
    }
}

data class VehiclesUiState(
    val vehicles: List<Vehicle> = emptyList(),
    val isLoading: Boolean = true,
    val isSubmitting: Boolean = false,
    val error: AppError? = null,
    val form: VehicleFormState = VehicleFormState(),
)

class VehiclesViewModel(private val repo: VehicleRepository) : ViewModel() {

    private val _state = MutableStateFlow(VehiclesUiState())
    val state: StateFlow<VehiclesUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = repo.listVehicles()) {
                is AppResult.Success -> _state.update { it.copy(vehicles = result.data, isLoading = false) }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    fun onVehicleTypeChange(v: VehicleType) = updateForm { it.copy(vehicleType = v) }
    fun onPlateNoChange(v: String) = updateForm { it.copy(plateNo = v) }
    fun onMakeModelChange(v: String) = updateForm { it.copy(makeModel = v) }
    fun onWeightChange(v: String) = updateForm { it.copy(capacityWeightGrams = v.filter(Char::isDigit)) }
    fun onVolumeChange(v: String) = updateForm { it.copy(capacityVolumeCm3 = v.filter(Char::isDigit)) }
    fun onParcelsChange(v: String) = updateForm { it.copy(capacityParcels = v.filter(Char::isDigit)) }

    fun startEdit(vehicle: Vehicle) = updateForm {
        VehicleFormState(
            vehicleType = vehicle.vehicleType,
            plateNo = vehicle.plateNo.orEmpty(),
            makeModel = vehicle.makeModel.orEmpty(),
            capacityWeightGrams = vehicle.capacityWeightGrams.toString(),
            capacityVolumeCm3 = vehicle.capacityVolumeCm3.toString(),
            capacityParcels = vehicle.capacityParcels.toString(),
            editingId = vehicle.id,
        )
    }

    fun cancelEdit() = updateForm { VehicleFormState() }

    fun submit() {
        val form = _state.value.form
        val draft = form.toDraftOrNull() ?: return
        val editingId = form.editingId
        viewModelScope.launch {
            _state.update { it.copy(isSubmitting = true, error = null) }
            val result = if (editingId != null) repo.updateVehicle(editingId, draft) else repo.createVehicle(draft)
            when (result) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        isSubmitting = false,
                        vehicles = if (editingId != null) {
                            it.vehicles.map { v -> if (v.id == editingId) result.data else v }
                        } else {
                            listOf(result.data) + it.vehicles
                        },
                        form = VehicleFormState(),
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmitting = false, error = result.error) }
            }
        }
    }

    fun setActive(id: String, isActive: Boolean) {
        viewModelScope.launch {
            when (val result = repo.setVehicleActive(id, isActive)) {
                is AppResult.Success -> _state.update {
                    it.copy(vehicles = it.vehicles.map { v -> if (v.id == id) v.copy(isActive = isActive) else v })
                }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    private inline fun updateForm(transform: (VehicleFormState) -> VehicleFormState) =
        _state.update { it.copy(form = transform(it.form)) }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(private val repo: VehicleRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = VehiclesViewModel(repo) as T
    }
}
