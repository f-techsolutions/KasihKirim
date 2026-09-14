package com.ftechsolutions.kasihkirim.ui.admin

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AccountStatus
import com.ftechsolutions.kasihkirim.domain.model.AdminAccount
import com.ftechsolutions.kasihkirim.domain.model.AdminPayout
import com.ftechsolutions.kasihkirim.domain.model.CarrierApplication
import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
import com.ftechsolutions.kasihkirim.domain.model.PayoutStatus
import com.ftechsolutions.kasihkirim.domain.model.ProductReview
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.SellerApplication
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.repository.AdminRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val PENDING_SELLER = SellerApplication(
    id = "s1", businessName = "Kedai Aisyah", ssmRegNo = null,
    status = SellerStatus.SUBMITTED, reviewNote = null, createdAt = "2026-09-10T00:00:00Z",
)

private val PENDING_CARRIER = CarrierApplication(
    id = "c1", status = SellerStatus.SUBMITTED, homeCommunityName = "Kg Kepayan Baru",
    reviewNote = null, createdAt = "2026-09-10T00:00:00Z",
)

private val PENDING_PRODUCT = ProductReview(
    id = "p1", title = "Ikan Pari", description = null, status = ProductStatus.PENDING_REVIEW,
    priceSen = Sen(800), unit = "kg", sellerName = "Kedai Aisyah", createdAt = "2026-09-10T00:00:00Z",
)

private val OPEN_DISPUTE = Dispute(
    id = "d1", category = "not_as_described", description = "Ikan tidak segar.",
    status = DisputeStatus.OPEN, refundSen = Sen(0), holdsEscrow = true,
    resolutionNote = null, slaDueAt = "2026-09-13T00:00:00Z", createdAt = "2026-09-10T00:00:00Z",
)

private val ACTIVE_ACCOUNT = AdminAccount(
    id = "u1", phone = "+60191234567", fullName = "Aisyah Rahman", displayName = null,
    status = AccountStatus.ACTIVE, suspendedReason = null, createdAt = "2026-09-10T00:00:00Z",
)

private val REQUESTED_PAYOUT = AdminPayout(
    id = "pay1", payeeType = "carrier", payeeLabel = "Rahman bin Ahmad", amountSen = Sen(5000),
    status = PayoutStatus.REQUESTED, bankCode = "MBB", accountNoLast4 = "1234", holderName = "Rahman",
    reviewedBy = null, approvedBy = null, requestedAt = "2026-09-10T00:00:00Z",
)

private class FakeAdminRepository(
    var sellers: List<SellerApplication> = emptyList(),
    var carriers: List<CarrierApplication> = emptyList(),
    var products: List<ProductReview> = emptyList(),
    var disputes: List<Dispute> = emptyList(),
    var accounts: List<AdminAccount> = emptyList(),
    var payouts: List<AdminPayout> = emptyList(),
    var sellerResult: AppResult<Unit> = AppResult.Success(Unit),
    var carrierResult: AppResult<Unit> = AppResult.Success(Unit),
    var accountStatusResult: AppResult<Unit> = AppResult.Success(Unit),
    var reviewPayoutResult: AppResult<Unit> = AppResult.Success(Unit),
    var approvePayoutResult: AppResult<Unit> = AppResult.Success(Unit),
    var markPayoutPaidResult: AppResult<Unit> = AppResult.Success(Unit),
    var markPayoutFailedResult: AppResult<Unit> = AppResult.Success(Unit),
) : AdminRepository {
    var sellerCalls = mutableListOf<Triple<String, SellerStatus, String?>>()
    var carrierCalls = mutableListOf<Triple<String, SellerStatus, String?>>()
    var productCalls = mutableListOf<Triple<String, ProductStatus, String?>>()
    var disputeCalls = mutableListOf<Triple<String, DisputeStatus, Long>>()
    var accountStatusCalls = mutableListOf<Triple<String, AccountStatus, String?>>()
    var searchCalls = mutableListOf<String>()
    var reviewPayoutCalls = mutableListOf<Triple<String, Boolean, String?>>()
    var approvePayoutCalls = mutableListOf<Triple<String, Boolean, String?>>()
    var markPayoutPaidCalls = mutableListOf<Pair<String, String?>>()
    var markPayoutFailedCalls = mutableListOf<Pair<String, String>>()
    var listCalls = 0

    override suspend fun listSellerApplications(): AppResult<List<SellerApplication>> {
        listCalls++
        return AppResult.Success(sellers)
    }

    override suspend fun setSellerStatus(sellerId: String, status: SellerStatus, reason: String?): AppResult<Unit> {
        sellerCalls += Triple(sellerId, status, reason)
        return sellerResult
    }

    override suspend fun listCarrierApplications(): AppResult<List<CarrierApplication>> = AppResult.Success(carriers)

    override suspend fun setCarrierStatus(carrierId: String, status: SellerStatus, reason: String?): AppResult<Unit> {
        carrierCalls += Triple(carrierId, status, reason)
        return carrierResult
    }

    override suspend fun listProductReviews(): AppResult<List<ProductReview>> = AppResult.Success(products)

    override suspend fun setProductStatus(
        productId: String,
        status: ProductStatus,
        rejectionReason: String?,
    ): AppResult<Unit> {
        productCalls += Triple(productId, status, rejectionReason)
        return AppResult.Success(Unit)
    }

    override suspend fun listOpenDisputes(): AppResult<List<Dispute>> = AppResult.Success(disputes)

    override suspend fun resolveDispute(
        disputeId: String,
        status: DisputeStatus,
        note: String?,
        refundSen: Long,
    ): AppResult<Unit> {
        disputeCalls += Triple(disputeId, status, refundSen)
        return AppResult.Success(Unit)
    }

    override suspend fun searchAccounts(query: String): AppResult<List<AdminAccount>> {
        searchCalls += query
        return AppResult.Success(accounts)
    }

    override suspend fun setAccountStatus(userId: String, status: AccountStatus, reason: String?): AppResult<Unit> {
        accountStatusCalls += Triple(userId, status, reason)
        return accountStatusResult
    }

    override suspend fun listPayouts(): AppResult<List<AdminPayout>> = AppResult.Success(payouts)

    override suspend fun reviewPayout(payoutId: String, approve: Boolean, reason: String?): AppResult<Unit> {
        reviewPayoutCalls += Triple(payoutId, approve, reason)
        return reviewPayoutResult
    }

    override suspend fun approvePayout(payoutId: String, approve: Boolean, reason: String?): AppResult<Unit> {
        approvePayoutCalls += Triple(payoutId, approve, reason)
        return approvePayoutResult
    }

    override suspend fun markPayoutPaid(payoutId: String, providerRef: String?): AppResult<Unit> {
        markPayoutPaidCalls += payoutId to providerRef
        return markPayoutPaidResult
    }

    override suspend fun markPayoutFailed(payoutId: String, reason: String): AppResult<Unit> {
        markPayoutFailedCalls += payoutId to reason
        return markPayoutFailedResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class AdminViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `all four queues load on construction, sellers first`() = runTest(dispatcher) {
        val vm = AdminViewModel(
            FakeAdminRepository(
                sellers = listOf(PENDING_SELLER),
                carriers = listOf(PENDING_CARRIER),
                products = listOf(PENDING_PRODUCT),
                disputes = listOf(OPEN_DISPUTE),
            ),
        )
        advanceUntilIdle()

        assertEquals(AdminQueue.SELLERS, vm.state.value.queue)
        assertEquals(1, vm.state.value.sellers.size)
        assertEquals(1, vm.state.value.carriers.size)
        assertEquals(1, vm.state.value.products.size)
        assertEquals(1, vm.state.value.disputes.size)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `approving a seller sends APPROVED and reloads the queues`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(sellers = listOf(PENDING_SELLER))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()
        val loadsAfterInit = repo.listCalls

        vm.decideSeller("s1", SellerStatus.APPROVED); advanceUntilIdle()

        assertEquals(listOf(Triple("s1", SellerStatus.APPROVED, null)), repo.sellerCalls)
        assertTrue("queue is re-read from the server, not patched locally", repo.listCalls > loadsAfterInit)
        assertNull(vm.state.value.decidingId)
    }

    @Test fun `approving a seller warns that the role only lands at next sign-in`() = runTest(dispatcher) {
        val vm = AdminViewModel(FakeAdminRepository(sellers = listOf(PENDING_SELLER)))
        advanceUntilIdle()

        vm.decideSeller("s1", SellerStatus.APPROVED); advanceUntilIdle()

        assertEquals(AdminNotice.SELLER_APPROVED_MUST_RESIGN, vm.state.value.notice)

        vm.dismissNotice()
        assertNull(vm.state.value.notice)
    }

    @Test fun `rejecting carries the reason through to the repository`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(sellers = listOf(PENDING_SELLER))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.decideSeller("s1", SellerStatus.REJECTED, "SSM number does not match."); advanceUntilIdle()

        assertEquals(
            listOf(Triple("s1", SellerStatus.REJECTED, "SSM number does not match.")),
            repo.sellerCalls,
        )
        assertNull("a rejection is not an approval, so no re-sign-in notice", vm.state.value.notice)
    }

    @Test fun `approving a carrier sends APPROVED and reloads the queues`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(carriers = listOf(PENDING_CARRIER))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()
        val loadsAfterInit = repo.listCalls

        vm.decideCarrier("c1", SellerStatus.APPROVED); advanceUntilIdle()

        assertEquals(listOf(Triple("c1", SellerStatus.APPROVED, null)), repo.carrierCalls)
        assertTrue("queue is re-read from the server, not patched locally", repo.listCalls > loadsAfterInit)
        assertNull(vm.state.value.decidingId)
    }

    @Test fun `approving a carrier warns that the role only lands at next sign-in`() = runTest(dispatcher) {
        val vm = AdminViewModel(FakeAdminRepository(carriers = listOf(PENDING_CARRIER)))
        advanceUntilIdle()

        vm.decideCarrier("c1", SellerStatus.APPROVED); advanceUntilIdle()

        assertEquals(AdminNotice.CARRIER_APPROVED_MUST_RESIGN, vm.state.value.notice)

        vm.dismissNotice()
        assertNull(vm.state.value.notice)
    }

    @Test fun `rejecting a carrier carries the reason through, with no re-sign-in notice`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(carriers = listOf(PENDING_CARRIER))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.decideCarrier("c1", SellerStatus.REJECTED, "Vehicle documents incomplete."); advanceUntilIdle()

        assertEquals(
            listOf(Triple("c1", SellerStatus.REJECTED, "Vehicle documents incomplete.")),
            repo.carrierCalls,
        )
        assertNull(vm.state.value.notice)
    }

    @Test fun `publishing a product sends ACTIVE`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(products = listOf(PENDING_PRODUCT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.decideProduct("p1", ProductStatus.ACTIVE); advanceUntilIdle()

        assertEquals(listOf(Triple("p1", ProductStatus.ACTIVE, null)), repo.productCalls)
    }

    @Test fun `resolving a dispute passes the refund amount through`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(disputes = listOf(OPEN_DISPUTE))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.resolveDispute("d1", DisputeStatus.RESOLVED_REFUND_FULL, "Refunded in full.", 800)
        advanceUntilIdle()

        assertEquals(listOf(Triple("d1", DisputeStatus.RESOLVED_REFUND_FULL, 800L)), repo.disputeCalls)
    }

    @Test fun `a failed decision surfaces the error and clears the busy row`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(
            sellers = listOf(PENDING_SELLER),
            sellerResult = AppResult.Failure(AppError.NotAuthorized),
        )
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.decideSeller("s1", SellerStatus.APPROVED); advanceUntilIdle()

        assertEquals(AppError.NotAuthorized, vm.state.value.error)
        assertNull(vm.state.value.decidingId)
        assertNull(vm.state.value.notice)
    }

    @Test fun `a blank account query is refused client-side, no repository call`() = runTest(dispatcher) {
        val repo = FakeAdminRepository()
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.onAccountQueryChange("   ")
        vm.searchAccounts(); advanceUntilIdle()

        assertTrue(repo.searchCalls.isEmpty())
        assertTrue(vm.state.value.accounts.isEmpty())
    }

    @Test fun `searching accounts populates the accounts list`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(accounts = listOf(ACTIVE_ACCOUNT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.onAccountQueryChange("aisyah")
        vm.searchAccounts(); advanceUntilIdle()

        assertEquals(listOf("aisyah"), repo.searchCalls)
        assertEquals(listOf(ACTIVE_ACCOUNT), vm.state.value.accounts)
        assertFalse(vm.state.value.isSearchingAccounts)
    }

    @Test fun `suspending an account carries the reason and re-runs the search`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(accounts = listOf(ACTIVE_ACCOUNT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()
        vm.onAccountQueryChange("aisyah")
        vm.searchAccounts(); advanceUntilIdle()
        val searchesAfterFirst = repo.searchCalls.size

        vm.setAccountStatus("u1", AccountStatus.SUSPENDED, "reported by another user")
        advanceUntilIdle()

        assertEquals(
            listOf(Triple("u1", AccountStatus.SUSPENDED, "reported by another user")),
            repo.accountStatusCalls,
        )
        assertTrue("a successful status change re-runs the same search", repo.searchCalls.size > searchesAfterFirst)
        assertNull(vm.state.value.decidingId)
    }

    @Test fun `a failed account status change surfaces the error and clears the busy row`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(
            accounts = listOf(ACTIVE_ACCOUNT),
            accountStatusResult = AppResult.Failure(AppError.Server("CANNOT_ACT_ON_SELF")),
        )
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.setAccountStatus("u1", AccountStatus.SUSPENDED, null); advanceUntilIdle()

        assertEquals(AppError.Server("CANNOT_ACT_ON_SELF"), vm.state.value.error)
        assertNull(vm.state.value.decidingId)
    }

    @Test fun `payouts load alongside the other four queues`() = runTest(dispatcher) {
        val vm = AdminViewModel(FakeAdminRepository(payouts = listOf(REQUESTED_PAYOUT)))
        advanceUntilIdle()

        assertEquals(1, vm.state.value.payouts.size)
    }

    @Test fun `reviewing a payout carries the decision through and reloads`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(payouts = listOf(REQUESTED_PAYOUT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()
        val loadsAfterInit = repo.listCalls

        vm.reviewPayout("pay1", true); advanceUntilIdle()

        assertEquals(listOf(Triple("pay1", true, null)), repo.reviewPayoutCalls)
        assertTrue("queue is re-read from the server, not patched locally", repo.listCalls > loadsAfterInit)
        assertNull(vm.state.value.decidingId)
    }

    @Test fun `rejecting at the review step carries the reason through`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(payouts = listOf(REQUESTED_PAYOUT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.reviewPayout("pay1", false, "duplicate request"); advanceUntilIdle()

        assertEquals(listOf(Triple("pay1", false, "duplicate request")), repo.reviewPayoutCalls)
    }

    @Test fun `approving a payout carries the decision through`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(payouts = listOf(REQUESTED_PAYOUT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.approvePayout("pay1", true); advanceUntilIdle()

        assertEquals(listOf(Triple("pay1", true, null)), repo.approvePayoutCalls)
    }

    @Test fun `a maker-checker rejection surfaces as an ordinary error`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(
            payouts = listOf(REQUESTED_PAYOUT),
            approvePayoutResult = AppResult.Failure(AppError.Server("CANNOT_APPROVE_OWN_REVIEW")),
        )
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.approvePayout("pay1", true); advanceUntilIdle()

        assertEquals(AppError.Server("CANNOT_APPROVE_OWN_REVIEW"), vm.state.value.error)
        assertNull(vm.state.value.decidingId)
    }

    @Test fun `marking a payout paid carries the provider ref through`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(payouts = listOf(REQUESTED_PAYOUT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.markPayoutPaid("pay1", "MANUAL-REF-1"); advanceUntilIdle()

        assertEquals(listOf("pay1" to "MANUAL-REF-1"), repo.markPayoutPaidCalls)
    }

    @Test fun `marking a payout failed carries the reason through`() = runTest(dispatcher) {
        val repo = FakeAdminRepository(payouts = listOf(REQUESTED_PAYOUT))
        val vm = AdminViewModel(repo)
        advanceUntilIdle()

        vm.markPayoutFailed("pay1", "bank rejected the account details"); advanceUntilIdle()

        assertEquals(listOf("pay1" to "bank rejected the account details"), repo.markPayoutFailedCalls)
    }

    @Test fun `only final dispute statuses are treated as resolving`() {
        assertTrue(DisputeStatus.RESOLVED_REFUND_FULL.isFinal)
        assertTrue(DisputeStatus.RESOLVED_REFUND_PARTIAL.isFinal)
        assertTrue(DisputeStatus.RESOLVED_REJECTED.isFinal)
        assertTrue(DisputeStatus.RESOLVED_SPLIT.isFinal)
        assertTrue(DisputeStatus.CLOSED.isFinal)

        assertFalse(DisputeStatus.OPEN.isFinal)
        assertFalse(DisputeStatus.UNDER_REVIEW.isFinal)
        assertFalse(DisputeStatus.AWAITING_EVIDENCE.isFinal)
        assertFalse("DECIDED is a verdict, not yet a resolution", DisputeStatus.DECIDED.isFinal)
    }
}
