package com.ftechsolutions.kasihkirim.ui.deliveries

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.DisputeCategory
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
    carrierId = "carrier-1", requesterId = "customer-1",
)

private class FakeDeliveryRepository(
    var deliveries: List<Delivery> = listOf(MATCHED_DELIVERY),
    var transitionResult: AppResult<KirimStatus> = AppResult.Success(KirimStatus.AWAITING_PICKUP),
    var proofResult: AppResult<KirimStatus> = AppResult.Success(KirimStatus.PICKED_UP),
    var recordPurchaseResult: AppResult<KirimStatus> = AppResult.Success(KirimStatus.AWAITING_PICKUP),
    var openDisputeResult: AppResult<Unit> = AppResult.Success(Unit),
    var reviewedDeliveryIds: AppResult<Set<String>> = AppResult.Success(emptySet()),
    var submitReviewResult: AppResult<Unit> = AppResult.Success(Unit),
) : DeliveryRepository {
    var transitionCalls = 0
    var lastDeliveryId: String? = null
    var lastEvent: String? = null
    var proofCalls = 0
    var lastProofLeg: String? = null
    var lastProofBytes: ByteArray? = null
    var recordPurchaseCalls = 0
    var lastActualGoodsSen: Long? = null
    var openDisputeCalls = 0
    var lastDisputeCategory: String? = null
    var lastDisputeDescription: String? = null
    var submitReviewCalls = mutableListOf<Triple<String, Int, String?>>()

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

    override suspend fun recordPurchase(deliveryId: String, actualGoodsSen: Long): AppResult<KirimStatus> {
        recordPurchaseCalls++
        lastDeliveryId = deliveryId
        lastActualGoodsSen = actualGoodsSen
        return recordPurchaseResult
    }

    override suspend fun openDispute(deliveryId: String, category: String, description: String): AppResult<Unit> {
        openDisputeCalls++
        lastDeliveryId = deliveryId
        lastDisputeCategory = category
        lastDisputeDescription = description
        return openDisputeResult
    }

    override suspend fun listMyReviewedDeliveryIds(): AppResult<Set<String>> = reviewedDeliveryIds

    override suspend fun submitReview(deliveryId: String, rating: Int, comment: String?): AppResult<Unit> {
        submitReviewCalls += Triple(deliveryId, rating, comment)
        return submitReviewResult
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

    @Test fun `requestRecordPurchase opens the dialog for the right delivery`() = runTest(dispatcher) {
        val vm = DeliveriesViewModel(FakeDeliveryRepository())
        advanceUntilIdle()

        vm.requestRecordPurchase("d1")

        assertEquals("d1", vm.state.value.recordPurchaseDeliveryId)
    }

    @Test fun `cancelRecordPurchase closes the dialog without calling the backend`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRecordPurchase("d1")
        vm.cancelRecordPurchase()

        assertNull(vm.state.value.recordPurchaseDeliveryId)
        assertEquals(0, repo.recordPurchaseCalls)
    }

    @Test fun `recordPurchase sends the delivery id and amount, then reloads`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRecordPurchase("d1")
        vm.recordPurchase(3200L); advanceUntilIdle()

        assertEquals(1, repo.recordPurchaseCalls)
        assertEquals("d1", repo.lastDeliveryId)
        assertEquals(3200L, repo.lastActualGoodsSen)
        assertNull(vm.state.value.recordPurchaseDeliveryId)
        assertNull(vm.state.value.transitioningId)
    }

    @Test fun `recordPurchase with no delivery pending is a no-op`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.recordPurchase(3200L); advanceUntilIdle()

        assertEquals(0, repo.recordPurchaseCalls)
    }

    @Test fun `a rejected purchase surfaces BUDGET_EXCEEDED_NEEDS_VARIANCE and clears the dialog`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository(
            recordPurchaseResult = AppResult.Failure(AppError.Server("BUDGET_EXCEEDED_NEEDS_VARIANCE")),
        )
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRecordPurchase("d1")
        vm.recordPurchase(9999L); advanceUntilIdle()

        assertNull(vm.state.value.recordPurchaseDeliveryId)
        assertNull(vm.state.value.transitioningId)
        assertEquals(AppError.Server("BUDGET_EXCEEDED_NEEDS_VARIANCE"), vm.state.value.error)
    }

    @Test fun `requestOpenDispute opens the dialog for the right delivery and resets its fields`() = runTest(dispatcher) {
        val vm = DeliveriesViewModel(FakeDeliveryRepository())
        advanceUntilIdle()

        vm.onDisputeCategorySelected(DisputeCategory.DAMAGED)
        vm.onDisputeDescriptionChange("stale text from a previous delivery")
        vm.requestOpenDispute("d1")

        assertEquals("d1", vm.state.value.openDisputeDeliveryId)
        assertEquals(DisputeCategory.OTHER, vm.state.value.disputeCategory)
        assertEquals("", vm.state.value.disputeDescription)
    }

    @Test fun `cancelOpenDispute closes the dialog without calling the backend`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestOpenDispute("d1")
        vm.cancelOpenDispute()

        assertNull(vm.state.value.openDisputeDeliveryId)
        assertEquals(0, repo.openDisputeCalls)
    }

    @Test fun `submitDispute sends the delivery id, category and description, then reloads`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestOpenDispute("d1")
        vm.onDisputeCategorySelected(DisputeCategory.PAYMENT)
        vm.onDisputeDescriptionChange("  Bayaran tunai tidak mencukupi  ")
        vm.submitDispute(); advanceUntilIdle()

        assertEquals(1, repo.openDisputeCalls)
        assertEquals("d1", repo.lastDeliveryId)
        assertEquals("payment", repo.lastDisputeCategory)
        assertEquals("Bayaran tunai tidak mencukupi", repo.lastDisputeDescription)
        assertNull(vm.state.value.openDisputeDeliveryId)
        assertNull(vm.state.value.transitioningId)
    }

    @Test fun `submitDispute with no delivery pending is a no-op`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.submitDispute(); advanceUntilIdle()

        assertEquals(0, repo.openDisputeCalls)
    }

    @Test fun `a rejected dispute filing surfaces DISPUTE_ALREADY_OPEN and clears the dialog`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository(
            openDisputeResult = AppResult.Failure(AppError.Server("DISPUTE_ALREADY_OPEN")),
        )
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestOpenDispute("d1")
        vm.onDisputeDescriptionChange("Barang sampai dalam keadaan rosak")
        vm.submitDispute(); advanceUntilIdle()

        assertNull(vm.state.value.openDisputeDeliveryId)
        assertNull(vm.state.value.transitioningId)
        assertEquals(AppError.Server("DISPUTE_ALREADY_OPEN"), vm.state.value.error)
    }

    @Test fun `reviewed delivery ids load alongside the delivery list`() = runTest(dispatcher) {
        val vm = DeliveriesViewModel(
            FakeDeliveryRepository(reviewedDeliveryIds = AppResult.Success(setOf("d1"))),
        )
        advanceUntilIdle()

        assertEquals(setOf("d1"), vm.state.value.reviewedDeliveryIds)
    }

    @Test fun `requestRate opens the dialog and resets its fields to the default`() = runTest(dispatcher) {
        val vm = DeliveriesViewModel(FakeDeliveryRepository())
        advanceUntilIdle()

        vm.onRatingValueChange(2)
        vm.onRatingCommentChange("stale text from a previous delivery")
        vm.requestRate("d1")

        assertEquals("d1", vm.state.value.rateDeliveryId)
        assertEquals(5, vm.state.value.ratingValue)
        assertEquals("", vm.state.value.ratingComment)
    }

    @Test fun `cancelRate closes the dialog without calling the backend`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRate("d1")
        vm.cancelRate()

        assertNull(vm.state.value.rateDeliveryId)
        assertEquals(0, repo.submitReviewCalls.size)
    }

    @Test fun `submitRating sends the delivery id, star value and trimmed comment, then reloads`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRate("d1")
        vm.onRatingValueChange(4)
        vm.onRatingCommentChange("  Penghantaran tepat masa  ")
        vm.submitRating(); advanceUntilIdle()

        assertEquals(listOf(Triple("d1", 4, "Penghantaran tepat masa")), repo.submitReviewCalls)
        assertNull(vm.state.value.rateDeliveryId)
        assertNull(vm.state.value.transitioningId)
    }

    @Test fun `submitRating with an empty comment sends null, not a blank string`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRate("d1")
        vm.submitRating(); advanceUntilIdle()

        assertEquals(listOf(Triple("d1", 5, null)), repo.submitReviewCalls)
    }

    @Test fun `submitRating with no delivery pending is a no-op`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository()
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.submitRating(); advanceUntilIdle()

        assertEquals(0, repo.submitReviewCalls.size)
    }

    @Test fun `a rejected rating surfaces EDIT_WINDOW_CLOSED and clears the dialog`() = runTest(dispatcher) {
        val repo = FakeDeliveryRepository(
            submitReviewResult = AppResult.Failure(AppError.Server("EDIT_WINDOW_CLOSED")),
        )
        val vm = DeliveriesViewModel(repo)
        advanceUntilIdle()

        vm.requestRate("d1")
        vm.submitRating(); advanceUntilIdle()

        assertNull(vm.state.value.rateDeliveryId)
        assertNull(vm.state.value.transitioningId)
        assertEquals(AppError.Server("EDIT_WINDOW_CLOSED"), vm.state.value.error)
    }
}
