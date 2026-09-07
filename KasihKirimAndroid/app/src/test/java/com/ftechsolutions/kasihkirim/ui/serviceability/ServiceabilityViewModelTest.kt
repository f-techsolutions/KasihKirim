package com.ftechsolutions.kasihkirim.ui.serviceability

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val KK = Community(id = "c1", name = "Kota Kinabalu", type = "bandar", district = "Kota Kinabalu", state = "Sabah", nodeId = "n1")
private val SANDAKAN_NO_NODE = Community(id = "c2", name = "Sandakan", type = "bandar", district = "Sandakan", state = "Sabah", nodeId = null)

private class FakeGeographyRepository(
    var communities: List<Community> = listOf(KK, SANDAKAN_NO_NODE),
    var serviceabilityResult: AppResult<Serviceability> = AppResult.Success(
        Serviceability.Serviceable("Kota Kinabalu", "Beluran", 42.0, 90, false, 2),
    ),
) : AddressRepository {
    var checkCalls = 0

    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> =
        AppResult.Success(communities.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) })

    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> {
        checkCalls++
        return serviceabilityResult
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class ServiceabilityViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `canCheck requires both sides to have a resolved route node`() = runTest(dispatcher) {
        val vm = ServiceabilityViewModel(FakeGeographyRepository())

        vm.onOriginSelected(KK)
        assertFalse("destination not chosen yet", vm.state.value.form.canCheck)

        vm.onDestSelected(SANDAKAN_NO_NODE)
        assertFalse("destination has no route node", vm.state.value.form.canCheck)
    }

    @Test fun `check is a no-op without two resolved nodes`() = runTest(dispatcher) {
        val repo = FakeGeographyRepository()
        val vm = ServiceabilityViewModel(repo)

        vm.onOriginSelected(KK)
        vm.check(); advanceUntilIdle()

        assertEquals(0, repo.checkCalls)
        assertNull(vm.state.value.result)
    }

    @Test fun `successful check surfaces the result`() = runTest(dispatcher) {
        val repo = FakeGeographyRepository()
        val secondNode = KK.copy(id = "c3", name = "Beluran", nodeId = "n2")
        val vm = ServiceabilityViewModel(repo)

        vm.onOriginSelected(KK)
        vm.onDestSelected(secondNode)
        vm.check(); advanceUntilIdle()

        assertEquals(1, repo.checkCalls)
        assertTrue(vm.state.value.result is Serviceability.Serviceable)
        assertFalse(vm.state.value.isChecking)
    }

    @Test fun `failed check surfaces the error and clears isChecking`() = runTest(dispatcher) {
        val repo = FakeGeographyRepository(
            serviceabilityResult = AppResult.Failure(com.ftechsolutions.kasihkirim.core.result.AppError.Network),
        )
        val secondNode = KK.copy(id = "c3", name = "Beluran", nodeId = "n2")
        val vm = ServiceabilityViewModel(repo)

        vm.onOriginSelected(KK)
        vm.onDestSelected(secondNode)
        vm.check(); advanceUntilIdle()

        assertNull(vm.state.value.result)
        assertFalse(vm.state.value.isChecking)
        assertNotNull(vm.state.value.error)
    }
}
