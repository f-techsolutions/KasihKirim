package com.ftechsolutions.kasihkirim.ui.deliveries

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val MATCHED_DELIVERY = Delivery(
    id = "d1", status = KirimStatus.MATCHED, kirimType = KirimType.HANTAR,
    referenceCode = "KK-2609-000001", itemDescription = "Ikan kering",
    codAmountSen = Sen(5000), carrierEarningSen = Sen(1350), failureReason = null,
    matchedAt = "2026-09-08T00:00:00Z",
)

private class FakeDeliveryRepository(
    var deliveries: List<Delivery> = listOf(MATCHED_DELIVERY),
    var transitionResult: AppResult<KirimStatus> = AppResult.Success(KirimStatus.AWAITING_PICKUP),
    var proofResult: AppResult<KirimStatus> = AppResult.Success(KirimStatus.PICKED_UP),
) : DeliveryRepository {
    var transitionCalls = 0
    var lastDeliveryId: String? = null
    var lastEvent: String? = null
    var proofCalls = 0
    var lastProofLeg: String? = null
    var lastProofBytes: ByteArray? = null

    override suspend fun listMyDeliveries(): AppResult<List<Delivery>> = AppResult.Success(deliveries)

    override suspend fun transition(deliveryId: String, event: String): AppResult<KirimStatus> {
        transitionCalls++
        lastDeliveryId = deliveryId
        lastEvent = event
        return transitionResult
    }

    override suspend fun submitProofAndTransition(
        deliveryId: String,
        leg: String,
        event: String,
        photoBytes: ByteArray,
    ): AppResult<KirimStatus> {
        proofCalls++
        lastDeliveryId = deliveryId
        lastProofLeg = leg
        lastEvent = event
        lastProofBytes = photoBytes
        return proofResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class DeliveriesViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `loads the caller's own deliveries on construction`() = runTest(dispatcher) {
        val vm = DeliveriesViewModel(FakeDeliveryRepository())
        advanceUntilIdle()

        assertEquals(1, vm.state.value.deliveries.size)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `transition sends the delivery id and event, then reloads`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.transition("d1", "GO_TO_PICKUP"); advanceUntilIdle()

        assertEquals(1, repo.transitionCalls)
        assertEquals("d1", repo.lastDeliveryId)
        assertEquals("GO_TO_PICKUP", repo.lastEvent)
        assertNull(vm.state.value.transitioningId)
    }

    @Test fun `a failed transition surfaces the error and clears transitioningId`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository(transitionResult = AppResult.Failure(AppError.Server("STATE_INVALID_TRANSITION")))
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.transition("d1", "GO_TO_PICKUP"); advanceUntilIdle()

        assertNull(vm.state.value.transitioningId)
        assertEquals(AppError.Server("STATE_INVALID_TRANSITION"), vm.state.value.error)
    }

    @Test fun `requestProof opens the pending-proof step for the right delivery, leg and event`() = runTest(dispatcher) {
        val vm = DeliveriesViewModel(FakeDeliveryRepository())
        advanceUntilIdle()

        vm.requestProof("d1", "pickup", "CONFIRM_PICKUP")

        val pending = vm.state.value.pendingProof
        assertEquals("d1", pending?.deliveryId)
        assertEquals("pickup", pending?.leg)
        assertEquals("CONFIRM_PICKUP", pending?.event)
    }

    @Test fun `cancelProof closes the pending-proof step without calling the backend`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestProof("d1", "pickup", "CONFIRM_PICKUP")
        vm.cancelProof()

        assertNull(vm.state.value.pendingProof)
        assertEquals(0, repo.proofCalls)
    }

    @Test fun `submitProof uploads the photo for the pending leg and event, then reloads`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestProof("d1", "pickup", "CONFIRM_PICKUP")
        vm.submitProof(byteArrayOf(1, 2, 3)); advanceUntilIdle()

        assertEquals(1, repo.proofCalls)
        assertEquals("d1", repo.lastDeliveryId)
        assertEquals("pickup", repo.lastProofLeg)
        assertEquals("CONFIRM_PICKUP", repo.lastEvent)
        assertArrayEquals(byteArrayOf(1, 2, 3), repo.lastProofBytes)
        assertNull(vm.state.value.pendingProof)
        assertNull(vm.state.value.transitioningId)
    }

    @Test fun `submitProof with no pending proof is a no-op`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.submitProof(byteArrayOf(1)); advanceUntilIdle()

        assertEquals(0, repo.proofCalls)
    }

    @Test fun `a failed proof submission surfaces the error and clears pendingProof`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository(proofResult = AppResult.Failure(AppError.Server("PROOF_REQUIRED")))
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestProof("d1", "pickup", "CONFIRM_PICKUP")
        vm.submitProof(byteArrayOf(1)); advanceUntilIdle()

        assertNull(vm.state.value.pendingProof)
        assertNull(vm.state.value.transitioningId)
        assertEquals(AppError.Server("PROOF_REQUIRED"), vm.state.value.error)
    }
}
