package com.ftechsolutions.kasihkirim.ui.trips

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.NewVehicle
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.model.VehicleType
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val BELURAN = Community(id = "c1", name = "Beluran", type = "pekan", district = "Beluran", state = "Sabah", nodeId = "n1")
private val KK = Community(id = "c2", name = "Kota Kinabalu", type = "bandar", district = "Kota Kinabalu", state = "Sabah", nodeId = "n2")
private val NO_NODE = Community(id = "c3", name = "Sandakan", type = "bandar", district = "Sandakan", state = "Sabah", nodeId = null)
private val PICKUP = Vehicle(
    id = "v1", vehicleType = VehicleType.PICKUP, plateNo = "SAB1234", makeModel = "Hilux",
    capacityWeightGrams = 50000, capacityVolumeCm3 = 500000, capacityParcels = 8, isActive = true,
)

private class FakeVehicleRepository(var vehicles: List<Vehicle> = listOf(PICKUP)) : VehicleRepository {
    override suspend fun listVehicles(): AppResult<List<Vehicle>> = AppResult.Success(vehicles)
    override suspend fun createVehicle(draft: NewVehicle) = throw NotImplementedError()
    override suspend fun updateVehicle(id: String, draft: NewVehicle) = throw NotImplementedError()
    override suspend fun setVehicleActive(id: String, isActive: Boolean) = throw NotImplementedError()
}

private class FakeAddressRepository(var communities: List<Community> = listOf(BELURAN, KK, NO_NODE)) : AddressRepository {
    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String) = throw NotImplementedError()

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> =
        AppResult.Success(communities.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) })
}

private class FakeTripRepository(
    var trips: List<Trip> = emptyList(),
    var createResult: AppResult<Trip>? = null,
) : TripRepository {
    var createCalls = 0
    var lastDraft: NewTripDraft? = null

    override suspend fun listMyTrips(): AppResult<List<Trip>> = AppResult.Success(trips)

    override suspend fun createTrip(draft: NewTripDraft): AppResult<Trip> {
        createCalls++
        lastDraft = draft
        return createResult ?: AppResult.Success(
            Trip(
                id = "t1", status = TripStatus.ANNOUNCED, originNodeId = draft.originNodeId,
                destNodeId = draft.destNodeId, departAt = draft.departAtIso,
                capacityWeightGrams = 50000, capacityVolumeCm3 = 500000, capacityParcels = 8,
                reservedWeightGrams = 0, reservedVolumeCm3 = 0, reservedParcels = 0,
            ),
        )
    }

    override suspend fun acceptOffer(tripId: String, kirimId: String): AppResult<Unit> = throw NotImplementedError()
    override suspend fun sendCapacityInvite(tripId: String) = throw NotImplementedError()
}

@OptIn(ExperimentalCoroutinesApi::class)
class TripsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(
        tripRepo: FakeTripRepository = FakeTripRepository(),
        vehicleRepo: FakeVehicleRepository = FakeVehicleRepository(),
        addressRepo: FakeAddressRepository = FakeAddressRepository(),
    ) = Triple(TripsViewModel(tripRepo, vehicleRepo, addressRepo), tripRepo, vehicleRepo)

    @Test fun `loads trips, active vehicles and a node name map on construction`() = runTest(dispatcher) {
        val (vm, _, _) = vm(
            tripRepo = FakeTripRepository(trips = listOf(
                Trip("t0", TripStatus.ANNOUNCED, "n1", "n2", "2026-01-01T00:00:00Z", 50000, 500000, 8, 0, 0, 0),
            )),
            vehicleRepo = FakeVehicleRepository(vehicles = listOf(PICKUP, PICKUP.copy(id = "v2", isActive = false))),
        )
        advanceUntilIdle()

        assertEquals(1, vm.state.value.trips.size)
        assertFalse(vm.state.value.isLoading)
        assertEquals("only active vehicles are offered", 1, vm.state.value.vehicles.size)
        assertEquals("Beluran", vm.state.value.nodeNames["n1"])
        assertEquals("Kota Kinabalu", vm.state.value.nodeNames["n2"])
    }

    @Test fun `canSubmit requires a vehicle, both resolved nodes and a date`() = runTest(dispatcher) {
        val (vm, _, _) = vm()
        advanceUntilIdle()
        assertFalse(vm.state.value.form.canSubmit)

        vm.onVehicleSelected(PICKUP)
        vm.onOriginSelected(BELURAN)
        vm.onDestSelected(KK)
        assertFalse("no date chosen yet", vm.state.value.form.canSubmit)

        vm.onDepartDateChange(1_800_000_000_000L)
        assertTrue(vm.state.value.form.canSubmit)
    }

    @Test fun `a destination without a route node blocks submission`() = runTest(dispatcher) {
        val (vm, _, _) = vm()
        advanceUntilIdle()
        vm.onVehicleSelected(PICKUP)
        vm.onOriginSelected(BELURAN)
        vm.onDestSelected(NO_NODE)
        vm.onDepartDateChange(1_800_000_000_000L)

        assertFalse(vm.state.value.form.canSubmit)
    }

    @Test fun `createTrip sends the resolved node ids and prepends the result`() = runTest(dispatcher) {
        val (vm, tripRepo, _) = vm()
        advanceUntilIdle()
        vm.onVehicleSelected(PICKUP)
        vm.onOriginSelected(BELURAN)
        vm.onDestSelected(KK)
        vm.onDepartDateChange(1_800_000_000_000L)
        vm.onDepartTimeChange(9, 30)

        vm.createTrip(); advanceUntilIdle()

        assertEquals(1, tripRepo.createCalls)
        val draft = tripRepo.lastDraft!!
        assertEquals("v1", draft.vehicleId)
        assertEquals("n1", draft.originNodeId)
        assertEquals("n2", draft.destNodeId)
        assertEquals(1, vm.state.value.trips.size)
        assertFalse(vm.state.value.isSubmitting)
        assertFalse("form clears after a successful create", vm.state.value.form.canSubmit)
    }

    @Test fun `createTrip is a no-op while the form is invalid`() = runTest(dispatcher) {
        val (vm, tripRepo, _) = vm()
        advanceUntilIdle()

        vm.createTrip(); advanceUntilIdle()

        assertEquals(0, tripRepo.createCalls)
    }

    @Test fun `a failed create surfaces the error`() = runTest(dispatcher) {
        val tripRepo = FakeTripRepository(createResult = AppResult.Failure(AppError.Server("VEHICLE_NOT_FOUND")))
        val (vm, _, _) = vm(tripRepo)
        advanceUntilIdle()
        vm.onVehicleSelected(PICKUP)
        vm.onOriginSelected(BELURAN)
        vm.onDestSelected(KK)
        vm.onDepartDateChange(1_800_000_000_000L)

        vm.createTrip(); advanceUntilIdle()

        assertTrue(vm.state.value.trips.isEmpty())
        assertFalse(vm.state.value.isSubmitting)
        assertEquals(AppError.Server("VEHICLE_NOT_FOUND"), vm.state.value.error)
    }
}
