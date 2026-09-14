package com.ftechsolutions.kasihkirim.ui.board

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CapacityInvite
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import kotlinx.coroutines.CompletableDeferred
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

private val INVITE = CapacityInvite(id = "inv1", message = "Ada ruang kosong", originNodeId = "n1", destNodeId = "n2", expiresAt = "2099-01-01T00:00:00Z")

private class FakeKirimRepository(
    var boardItems: List<KirimSummary> = listOf(BOARD_ITEM),
    var invites: List<CapacityInvite> = emptyList(),
    var respondResult: AppResult<Unit>? = null,
    var respondGate: CompletableDeferred<Unit>? = null,
) : KirimRepository {
    var respondCalls = 0
    var lastRespondedInviteId: String? = null

    override suspend fun quoteKirim(draft: com.ftechsolutions.kasihkirim.domain.model.KirimDraft) = throw NotImplementedError()
    override suspend fun createKirim(submission: com.ftechsolutions.kasihkirim.domain.model.KirimSubmission) = throw NotImplementedError()
    override suspend fun listBoard(): AppResult<List<KirimSummary>> = AppResult.Success(boardItems)
    override suspend fun listMyKirims() = throw NotImplementedError()
    override suspend fun listMyInvites(): AppResult<List<CapacityInvite>> = AppResult.Success(invites)

    override suspend fun respondToInvite(inviteId: String): AppResult<Unit> {
        respondCalls++
        lastRespondedInviteId = inviteId
        respondGate?.await()
        return respondResult ?: AppResult.Success(Unit)
    }
}

private class FakeTripRepository(
    var trips: List<Trip> = listOf(ANNOUNCED_TRIP, DEPARTED_TRIP),
    var listMyTripsResult: AppResult<List<Trip>>? = null,
    var acceptResult: AppResult<Unit> = AppResult.Success(Unit),
) : TripRepository {
    var acceptCalls = 0
    var lastAcceptTripId: String? = null
    var lastAcceptKirimId: String? = null

    override suspend fun listMyTrips(): AppResult<List<Trip>> = listMyTripsResult ?: AppResult.Success(trips)
    override suspend fun createTrip(draft: NewTripDraft) = throw NotImplementedError()
    override suspend fun sendCapacityInvite(tripId: String) = throw NotImplementedError()

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

    /** Found on-device: a carrier whose 'carrier' role was granted but who
     *  has no public.carriers row yet makes listMyTrips() throw
     *  NOT_A_CARRIER (requireCarrierId() has nothing to read). That failure
     *  used to wipe out an otherwise-successful board load entirely -- the
     *  carrier saw zero listings and a bare error for a reason that had
     *  nothing to do with the board itself. */
    @Test fun `a failed trips load still shows the board, just with no eligible trips`() = runTest(dispatcher) {
        val tripRepo = FakeTripRepository(listMyTripsResult = AppResult.Failure(AppError.Server("NOT_A_CARRIER")))
        val vm = BoardViewModel(FakeKirimRepository(), tripRepo, FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        assertEquals("the board itself must still load", 1, vm.state.value.items.size)
        assertTrue(vm.state.value.eligibleTrips.isEmpty())
        assertNull("a trips-only failure must not surface as a board-wide error", vm.state.value.error)
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

    @Test fun `a marketplace listing's true COD total is carried through to state unchanged`() = runTest(dispatcher) {
        val pasaranItem = BOARD_ITEM.copy(
            id = "k2", kirimType = KirimType.PASARAN, deliveryFeeSen = Sen(500), codTotalSen = Sen(4000),
        )
        val vm = BoardViewModel(
            FakeKirimRepository(boardItems = listOf(BOARD_ITEM, pasaranItem)),
            FakeTripRepository(), FakeAddressRepository(), isCarrier = true,
        )
        advanceUntilIdle()

        val loaded = vm.state.value.items.first { it.id == "k2" }
        assertEquals(KirimType.PASARAN, loaded.kirimType)
        assertEquals(Sen(4000), loaded.codTotalSen)
        assertNull("a BELI/HANTAR item never carries a COD total", vm.state.value.items.first { it.id == "k1" }.codTotalSen)
    }

    @Test fun `respondToInvite ignores a second tap while the first is still in flight`() = runTest(dispatcher) {
        val gate = CompletableDeferred<Unit>()
        val kirimRepo = FakeKirimRepository(invites = listOf(INVITE), respondGate = gate)
        val vm = BoardViewModel(kirimRepo, FakeTripRepository(), FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        vm.respondToInvite("inv1")
        runCurrent()
        assertEquals("inv1", vm.state.value.respondingInviteId)

        vm.respondToInvite("inv1")
        runCurrent()
        assertEquals("only the first tap should reach the repository", 1, kirimRepo.respondCalls)

        gate.complete(Unit)
        advanceUntilIdle()
        assertNull(vm.state.value.respondingInviteId)
        assertTrue("inv1" in vm.state.value.respondedInviteIds)
    }

    @Test fun `a failed respondToInvite clears the busy flag and surfaces the error`() = runTest(dispatcher) {
        val kirimRepo = FakeKirimRepository(
            invites = listOf(INVITE),
            respondResult = AppResult.Failure(AppError.Network),
        )
        val vm = BoardViewModel(kirimRepo, FakeTripRepository(), FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        vm.respondToInvite("inv1"); advanceUntilIdle()

        assertNull(vm.state.value.respondingInviteId)
        assertEquals(AppError.Network, vm.state.value.error)
        assertFalse("inv1" in vm.state.value.respondedInviteIds)
    }

    @Test fun `respondToInvite clears a stale error left over from an earlier failure`() = runTest(dispatcher) {
        val tripRepo = FakeTripRepository(acceptResult = AppResult.Failure(AppError.Server("CAPACITY_EXCEEDED")))
        val kirimRepo = FakeKirimRepository(invites = listOf(INVITE))
        val vm = BoardViewModel(kirimRepo, tripRepo, FakeAddressRepository(), isCarrier = true)
        advanceUntilIdle()

        vm.acceptOffer("k1", "t1"); advanceUntilIdle()
        assertNotNull(vm.state.value.error)

        vm.respondToInvite("inv1"); advanceUntilIdle()

        assertNull("a successful, unrelated invite response should not leave a stale error on screen", vm.state.value.error)
    }
}
