package com.ftechsolutions.kasihkirim.ui.vehicles

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.NewVehicle
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.model.VehicleType
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val PICKUP = Vehicle(
    id = "v1", vehicleType = VehicleType.PICKUP, plateNo = "SAB1234", makeModel = "Hilux",
    capacityWeightGrams = 50000, capacityVolumeCm3 = 500000, capacityParcels = 8, isActive = true,
)

private class FakeVehicleRepository(var vehicles: List<Vehicle> = emptyList()) : VehicleRepository {
    var createCalls = 0
    var updateCalls = 0
    var setActiveCalls = 0

    override suspend fun listVehicles(): AppResult<List<Vehicle>> = AppResult.Success(vehicles)

    override suspend fun createVehicle(draft: NewVehicle): AppResult<Vehicle> {
        createCalls++
        val created = Vehicle(
            id = "new", vehicleType = draft.vehicleType, plateNo = draft.plateNo, makeModel = draft.makeModel,
            capacityWeightGrams = draft.capacityWeightGrams, capacityVolumeCm3 = draft.capacityVolumeCm3,
            capacityParcels = draft.capacityParcels, isActive = true,
        )
        vehicles = listOf(created) + vehicles
        return AppResult.Success(created)
    }

    override suspend fun updateVehicle(id: String, draft: NewVehicle): AppResult<Vehicle> {
        updateCalls++
        val existing = vehicles.first { it.id == id }
        val updated = existing.copy(
            vehicleType = draft.vehicleType, plateNo = draft.plateNo, makeModel = draft.makeModel,
            capacityWeightGrams = draft.capacityWeightGrams, capacityVolumeCm3 = draft.capacityVolumeCm3,
            capacityParcels = draft.capacityParcels,
        )
        vehicles = vehicles.map { if (it.id == id) updated else it }
        return AppResult.Success(updated)
    }

    override suspend fun setVehicleActive(id: String, isActive: Boolean): AppResult<Unit> {
        setActiveCalls++
        vehicles = vehicles.map { if (it.id == id) it.copy(isActive = isActive) else it }
        return AppResult.Success(Unit)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class VehiclesViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `loads vehicles on construction`() = runTest(dispatcher) {
        val vm = VehiclesViewModel(FakeVehicleRepository(vehicles = listOf(PICKUP)))
        advanceUntilIdle()
        assertEquals(1, vm.state.value.vehicles.size)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `submit requires all three positive capacity fields`() = runTest(dispatcher) {
        val vm = VehiclesViewModel(FakeVehicleRepository()); advanceUntilIdle()
        assertFalse(vm.state.value.form.canSubmit)

        vm.onWeightChange("50000")
        assertFalse(vm.state.value.form.canSubmit)
        vm.onVolumeChange("500000")
        assertFalse(vm.state.value.form.canSubmit)
        vm.onParcelsChange("8")
        assertTrue(vm.state.value.form.canSubmit)

        vm.onParcelsChange("0")
        assertFalse("zero parcels is invalid", vm.state.value.form.canSubmit)
    }

    @Test fun `successful submit prepends the new vehicle and clears the form`() = runTest(dispatcher) {
        val repo = FakeVehicleRepository()
        val vm = VehiclesViewModel(repo); advanceUntilIdle()
        vm.onVehicleTypeChange(VehicleType.BOAT)
        vm.onWeightChange("30000")
        vm.onVolumeChange("200000")
        vm.onParcelsChange("5")

        vm.submit(); advanceUntilIdle()

        assertEquals(1, repo.createCalls)
        assertEquals(1, vm.state.value.vehicles.size)
        assertEquals(VehicleType.BOAT, vm.state.value.vehicles.first().vehicleType)
        assertEquals("", vm.state.value.form.capacityWeightGrams)
        assertFalse(vm.state.value.isSubmitting)
    }

    @Test fun `startEdit populates the form and submit updates in place`() = runTest(dispatcher) {
        val repo = FakeVehicleRepository(vehicles = listOf(PICKUP))
        val vm = VehiclesViewModel(repo); advanceUntilIdle()

        vm.startEdit(PICKUP)
        assertTrue(vm.state.value.form.isEditing)
        assertEquals("50000", vm.state.value.form.capacityWeightGrams)

        vm.onMakeModelChange("Hilux Rogue")
        vm.submit(); advanceUntilIdle()

        assertEquals(1, repo.updateCalls)
        assertEquals(0, repo.createCalls)
        assertEquals("Hilux Rogue", vm.state.value.vehicles.first().makeModel)
        assertFalse("form clears after a successful update", vm.state.value.form.isEditing)
    }

    @Test fun `setActive toggles the vehicle without a full reload`() = runTest(dispatcher) {
        val repo = FakeVehicleRepository(vehicles = listOf(PICKUP))
        val vm = VehiclesViewModel(repo); advanceUntilIdle()

        vm.setActive("v1", false); advanceUntilIdle()

        assertEquals(1, repo.setActiveCalls)
        assertFalse(vm.state.value.vehicles.first().isActive)
    }
}
