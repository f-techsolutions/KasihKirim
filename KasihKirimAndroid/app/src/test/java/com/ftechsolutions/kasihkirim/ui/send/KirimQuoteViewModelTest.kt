package com.ftechsolutions.kasihkirim.ui.send

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimCreated
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.KirimSubmission
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val ORIGIN = Community(id = "c1", name = "Beluran", type = "pekan", district = "Beluran", state = "Sabah", nodeId = "n1")
private val DEST = Community(id = "c2", name = "Kota Kinabalu", type = "bandar", district = "Kota Kinabalu", state = "Sabah", nodeId = "n2")
private val NO_NODE = Community(id = "c3", name = "Sandakan", type = "bandar", district = "Sandakan", state = "Sabah", nodeId = null)
private val HOME_ADDR = Address("a1", "Rumah", "Aisyah", "+60123456789", ORIGIN, "Sebelah kedai runcit", true)
private val OFFICE_ADDR = Address("a2", "Pejabat", "Aisyah", "+60123456789", DEST, "Tingkat 2", false)

private class FakeAddressRepository(
    var communities: List<Community> = listOf(ORIGIN, DEST, NO_NODE),
    var addresses: List<Address> = listOf(HOME_ADDR, OFFICE_ADDR),
) : AddressRepository {
    override suspend fun listAddresses(): AppResult<List<Address>> = AppResult.Success(addresses)
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> =
        AppResult.Success(communities.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) })
}

private class FakeKirimRepository(
    var quoteResult: AppResult<KirimQuote> = AppResult.Success(
        KirimQuote(
            quoteId = "q1", expiresAt = "2026-09-08T00:00:00Z", corridorKm = 42.0, corridorBand = "district",
            goodsBudgetSen = Sen.ZERO, deliveryFeeSen = Sen(1500), commissionSen = Sen(150),
            orderTotalSen = Sen(1500), carrierEarningSen = Sen(1350), pricingRuleVersion = 1,
        ),
    ),
    var createResult: AppResult<KirimCreated> = AppResult.Success(
        KirimCreated(kirimId = "k1", referenceCode = "KK-2609-000001", expiresAt = "2026-09-11T00:00:00Z"),
    ),
) : KirimRepository {
    var quoteCalls = 0
    var lastDraft: KirimDraft? = null
    var createCalls = 0
    var lastSubmission: KirimSubmission? = null

    override suspend fun quoteKirim(draft: KirimDraft): AppResult<KirimQuote> {
        quoteCalls++
        lastDraft = draft
        return quoteResult
    }

    override suspend fun createKirim(submission: KirimSubmission): AppResult<KirimCreated> {
        createCalls++
        lastSubmission = submission
        return createResult
    }

    override suspend fun listBoard(): AppResult<List<KirimSummary>> = throw NotImplementedError()
    override suspend fun listMyKirims(): AppResult<List<KirimSummary>> = throw NotImplementedError()
    override suspend fun listMyInvites() = throw NotImplementedError()
    override suspend fun respondToInvite(inviteId: String) = throw NotImplementedError()
}

@OptIn(ExperimentalCoroutinesApi::class)
class KirimQuoteViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    private fun vm(kirimRepo: FakeKirimRepository = FakeKirimRepository(), addressRepo: FakeAddressRepository = FakeAddressRepository()) =
        Triple(KirimQuoteViewModel(kirimRepo, addressRepo), kirimRepo, addressRepo)

    @Test fun `canQuote requires category, valid weight and both nodes`() = runTest(dispatcher) {
        val (vm, _, _) = vm()

        assertFalse(vm.state.value.form.canQuote)

        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onOriginSelected(ORIGIN)
        assertFalse("destination not chosen", vm.state.value.form.canQuote)

        vm.onDestSelected(DEST)
        assertTrue(vm.state.value.form.canQuote)
    }

    @Test fun `weight outside 100-500000 grams is invalid`() = runTest(dispatcher) {
        val (vm, _, _) = vm()
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)

        vm.onWeightChange("50")
        assertFalse(vm.state.value.form.canQuote)

        vm.onWeightChange("500000")
        assertTrue(vm.state.value.form.canQuote)

        vm.onWeightChange("500001")
        assertFalse(vm.state.value.form.canQuote)
    }

    @Test fun `a community without a route node blocks quoting`() = runTest(dispatcher) {
        val (vm, _, _) = vm()
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(NO_NODE)

        assertFalse(vm.state.value.form.canQuote)
    }

    @Test fun `BELI requires a positive budget, HANTAR does not`() = runTest(dispatcher) {
        val (vm, _, _) = vm()
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)
        assertTrue("HANTAR needs no budget", vm.state.value.form.canQuote)

        vm.onKirimTypeChange(KirimType.BELI)
        assertFalse("BELI needs a budget", vm.state.value.form.canQuote)

        vm.onBudgetChange("50")
        assertTrue(vm.state.value.form.canQuote)
    }

    @Test fun `quote sends the resolved node ids and budget in sen`() = runTest(dispatcher) {
        val (vm, kirimRepo, _) = vm()
        vm.onKirimTypeChange(KirimType.BELI)
        vm.onCategorySelected(KirimCategory.BUAH)
        vm.onWeightChange("2000")
        vm.onBudgetChange("25.50")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)

        vm.quote(); advanceUntilIdle()

        assertEquals(1, kirimRepo.quoteCalls)
        val draft = kirimRepo.lastDraft!!
        assertEquals("n1", draft.originNodeId)
        assertEquals("n2", draft.destNodeId)
        assertEquals(2000, draft.estWeightGrams)
        assertEquals(2550L, draft.budgetSen)
        assertNotNull(vm.state.value.quote)
        assertFalse(vm.state.value.isQuoting)
    }

    @Test fun `quote is a no-op while the form is invalid`() = runTest(dispatcher) {
        val (vm, kirimRepo, _) = vm()

        vm.quote(); advanceUntilIdle()

        assertEquals(0, kirimRepo.quoteCalls)
    }

    @Test fun `a failed quote surfaces the error`() = runTest(dispatcher) {
        val kirimRepo = FakeKirimRepository(quoteResult = AppResult.Failure(AppError.Server("BUDGET_CAP_EXCEEDED")))
        val (vm, _, _) = vm(kirimRepo)
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)

        vm.quote(); advanceUntilIdle()

        assertNull(vm.state.value.quote)
        assertFalse(vm.state.value.isQuoting)
        assertEquals(AppError.Server("BUDGET_CAP_EXCEEDED"), vm.state.value.error)
    }

    @Test fun `loads the user's addresses on construction`() = runTest(dispatcher) {
        val (vm, _, _) = vm(); advanceUntilIdle()
        assertEquals(2, vm.state.value.addresses.size)
    }

    private suspend fun TestScope.quotedHantarVm(): Triple<KirimQuoteViewModel, FakeKirimRepository, FakeAddressRepository> {
        val triple = vm()
        val (vm, _, _) = triple
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)
        vm.quote(); advanceUntilIdle()
        return triple
    }

    @Test fun `canSubmit requires a description and a destination address`() = runTest(dispatcher) {
        val (vm, _, _) = quotedHantarVm()
        assertFalse(vm.state.value.form.canSubmit)

        vm.onItemDescriptionChange("Sayur segar")
        assertFalse("destination address still missing", vm.state.value.form.canSubmit)

        vm.onDestAddressSelected(OFFICE_ADDR)
        assertFalse("HANTAR also needs an origin address", vm.state.value.form.canSubmit)

        vm.onOriginAddressSelected(HOME_ADDR)
        assertTrue(vm.state.value.form.canSubmit)
    }

    @Test fun `BELI does not require an origin address to submit`() = runTest(dispatcher) {
        val (vm, _, _) = vm()
        vm.onKirimTypeChange(KirimType.BELI)
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onBudgetChange("50")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)
        vm.quote(); advanceUntilIdle()

        vm.onItemDescriptionChange("Sayur segar")
        vm.onDestAddressSelected(OFFICE_ADDR)

        assertTrue(vm.state.value.form.canSubmit)
    }

    @Test fun `submitKirim sends the quote id and selected addresses`() = runTest(dispatcher) {
        val (vm, kirimRepo, _) = quotedHantarVm()
        vm.onItemDescriptionChange("Sayur segar")
        vm.onDestAddressSelected(OFFICE_ADDR)
        vm.onOriginAddressSelected(HOME_ADDR)

        vm.submitKirim(); advanceUntilIdle()

        assertEquals(1, kirimRepo.createCalls)
        val submission = kirimRepo.lastSubmission!!
        assertEquals("q1", submission.quoteId)
        assertEquals("a2", submission.destAddressId)
        assertEquals("a1", submission.originAddressId)
        assertNotNull(vm.state.value.created)
        assertNull("quote clears after a successful submission", vm.state.value.quote)
        assertFalse(vm.state.value.isSubmitting)
    }

    @Test fun `submitKirim is a no-op while the form is invalid`() = runTest(dispatcher) {
        val (vm, kirimRepo, _) = quotedHantarVm()

        vm.submitKirim(); advanceUntilIdle()

        assertEquals(0, kirimRepo.createCalls)
    }

    @Test fun `a failed submission surfaces the error and keeps isSubmitting false`() = runTest(dispatcher) {
        val kirimRepo = FakeKirimRepository(createResult = AppResult.Failure(AppError.Server("QUOTE_EXPIRED")))
        val (vm, _, _) = vm(kirimRepo)
        vm.onCategorySelected(KirimCategory.SAYUR)
        vm.onWeightChange("500")
        vm.onOriginSelected(ORIGIN)
        vm.onDestSelected(DEST)
        vm.quote(); advanceUntilIdle()
        vm.onItemDescriptionChange("Sayur segar")
        vm.onDestAddressSelected(OFFICE_ADDR)
        vm.onOriginAddressSelected(HOME_ADDR)

        vm.submitKirim(); advanceUntilIdle()

        assertNull(vm.state.value.created)
        assertFalse(vm.state.value.isSubmitting)
        assertEquals(AppError.Server("QUOTE_EXPIRED"), vm.state.value.error)
    }
}
