package com.ftechsolutions.kasihkirim.ui.board

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val BELURAN = Community(id = "c1", name = "Beluran", type = "pekan", district = "Beluran", state = "Sabah", nodeId = "n1")
private val KK = Community(id = "c2", name = "Kota Kinabalu", type = "bandar", district = "Kota Kinabalu", state = "Sabah", nodeId = "n2")
private val BOARD_ITEM = KirimSummary(
    id = "k1", referenceCode = "KK-2609-000001", kirimType = KirimType.HANTAR, status = KirimStatus.POSTED,
    itemDescription = "Ikan kering", estWeightGrams = 2000, originNodeId = "n1", destNodeId = "n2",
    budgetCapSen = null, deliveryFeeSen = null, commissionSen = null, createdAt = "2026-09-08T00:00:00Z",
)
private val ANNOUNCED_TRIP = Trip("t1", TripStatus.ANNOUNCED, "n1", "n2", "2026-09-09T00:00:00Z", 50000, 500000, 8, 0, 0, 0)
private val DEPARTED_TRIP = Trip("t2", TripStatus.DEPARTED, "n1", "n2", "2026-09-08T00:00:00Z", 50000, 500000, 8, 0, 0, 0)

private class FakeAddressRepository(var communities: List<Community> = listOf(BELURAN, KK)) : AddressRepository {
    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> =
        AppResult.Success(communities.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) })
}

private class FakeKirimRepository(var boardItems: List<KirimSummary> = listOf(BOARD_ITEM)) : KirimRepository {
    override suspend fun quoteKirim(draft: com.ftechsolutions.kasihkirim.domain.model.KirimDraft) = throw NotImplementedError()
    override suspend fun createKirim(submission: com.ftechsolutions.kasihkirim.domain.model.KirimSubmission) = throw NotImplementedError()
    override suspend fun listBoard(): AppResult<List<KirimSummary>> = AppResult.Success(boardItems)
    override suspend fun listMyKirims() = throw NotImplementedError()
}

private class FakeTripRepository(
    var trips: List<Trip> = listOf(ANNOUNCED_TRIP, DEPARTED_TRIP),
    var acceptResult: AppResult<Unit> = AppResult.Success(Unit),
) : TripRepository {
    var acceptCalls = 0
    var lastAcceptTripId: String? = null
    var lastAcceptKirimId: String? = null

    override suspend fun listMyTrips(): AppResult<List<Trip>> = AppResult.Success(trips)
    override suspend fun createTrip(draft: NewTripDraft) = throw NotImplementedError()

    override suspend fun acceptOffer(tripId: String, kirimId: String): AppResult<Unit> {
        acceptCalls++
        lastAcceptTripId = tripId
        lastAcceptKirimId = kirimId
        return acceptResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class BoardViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `a carrier sees the board and only ANNOUNCED-BOARDING trips as eligible`() = runTest(dispatcher) {
        val vm = BoardViewModel(FakeKirimRepository(), FakeTripRepository(), FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        assertEquals(1, vm.state.value.items.size)
        assertEquals("only the ANNOUNCED trip is eligible, not the DEPARTED one", 1, vm.state.value.eligibleTrips.size)
        assertEquals("t1", vm.state.value.eligibleTrips.first().id)
        assertEquals("Beluran", vm.state.value.nodeNames["n1"])
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `a non-carrier never calls listMyTrips and sees an empty eligible list`() = runTest(dispatcher) {
        val tripRepo = FakeTripRepository()
        val vm = BoardViewModel(FakeKirimRepository(), tripRepo, FakeAddressRepository(), isCarrier = false)
        advanceUntilIdle()

        assertTrue(vm.state.value.eligibleTrips.isEmpty())
        assertEquals(1, vm.state.value.items.size)
    }

    @Test fun `acceptOffer sends the trip and kirim ids, then reloads the board`() = runTest(dispatcher) {
        val kirimRepo = FakeKirimRepository()
        val tripRepo = FakeTripRepository()
        val vm = BoardViewModel(kirimRepo, tripRepo, FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        vm.acceptOffer("k1", "t1"); advanceUntilIdle()

        assertEquals(1, tripRepo.acceptCalls)
        assertEquals("t1", tripRepo.lastAcceptTripId)
        assertEquals("k1", tripRepo.lastAcceptKirimId)
        assertNull(vm.state.value.acceptingKirimId)
    }

    @Test fun `a failed accept surfaces the error and clears acceptingKirimId`() = runTest(dispatcher) {
        val tripRepo = FakeTripRepository(acceptResult = AppResult.Failure(AppError.Server("CAPACITY_EXCEEDED")))
        val vm = BoardViewModel(FakeKirimRepository(), tripRepo, FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        vm.acceptOffer("k1", "t1"); advanceUntilIdle()

        assertNull(vm.state.value.acceptingKirimId)
        assertEquals(AppError.Server("CAPACITY_EXCEEDED"), vm.state.value.error)
    }
}
