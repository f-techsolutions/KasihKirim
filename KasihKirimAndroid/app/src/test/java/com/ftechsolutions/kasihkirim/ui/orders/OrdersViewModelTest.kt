package com.ftechsolutions.kasihkirim.ui.orders

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimSubmission
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
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

private val BELURAN = Community(id = "c1", name = "Beluran", type = "pekan", district = "Beluran", state = "Sabah", nodeId = "n1")
private val ORDER = KirimSummary(
    id = "k1", referenceCode = "KK-2609-000001", kirimType = KirimType.HANTAR, status = KirimStatus.MATCHED,
    itemDescription = "Ikan kering", estWeightGrams = 2000, originNodeId = "n1", destNodeId = "n2",
    budgetCapSen = null, deliveryFeeSen = null, commissionSen = null, createdAt = "2026-09-08T00:00:00Z",
)

private class FakeAddressRepository(var communities: List<Community> = listOf(BELURAN)) : AddressRepository {
    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> =
        AppResult.Success(communities.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) })
}

private class FakeKirimRepository(var ordersResult: AppResult<List<KirimSummary>> = AppResult.Success(listOf(ORDER))) : KirimRepository {
    override suspend fun quoteKirim(draft: KirimDraft) = throw NotImplementedError()
    override suspend fun createKirim(submission: KirimSubmission) = throw NotImplementedError()
    override suspend fun listBoard() = throw NotImplementedError()
    override suspend fun listMyKirims(): AppResult<List<KirimSummary>> = ordersResult
    override suspend fun listMyInvites() = throw NotImplementedError()
    override suspend fun respondToInvite(inviteId: String) = throw NotImplementedError()
}

@OptIn(ExperimentalCoroutinesApi::class)
class OrdersViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `loads the caller's own orders and a node name map on construction`() = runTest(dispatcher) {
        val vm = OrdersViewModel(FakeKirimRepository(), FakeAddressRepository())
        advanceUntilIdle()

        assertEquals(1, vm.state.value.orders.size)
        assertEquals("Beluran", vm.state.value.nodeNames["n1"])
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `a failed load surfaces the error`() = runTest(dispatcher) {
        val vm = OrdersViewModel(
            FakeKirimRepository(ordersResult = AppResult.Failure(AppError.Network)),
            FakeAddressRepository(),
        )
        advanceUntilIdle()

        assertTrue(vm.state.value.orders.isEmpty())
        assertFalse(vm.state.value.isLoading)
        assertEquals(AppError.Network, vm.state.value.error)
    }
}
