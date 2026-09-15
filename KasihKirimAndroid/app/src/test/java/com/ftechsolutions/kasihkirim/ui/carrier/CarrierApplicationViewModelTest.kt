package com.ftechsolutions.kasihkirim.ui.carrier

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierProfile
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewCarrier
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.CarrierRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val KEPAYAN = Community(id = "c1", name = "Kg Kepayan Baru", type = "kampung", district = "Kota Kinabalu", state = "Sabah", nodeId = "n1")

private val APPROVED_CARRIER = CarrierProfile(id = "cr1", status = SellerStatus.APPROVED, homeCommunityId = "c1")

private class FakeAddressRepository(var communities: List<Community> = listOf(KEPAYAN)) : AddressRepository {
    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()
    override suspend fun searchCommunities(query: String): AppResult<List<Community>> = AppResult.Success(communities)
}

private class FakeCarrierRepository(
    var carrier: CarrierProfile? = null,
    var applyResult: AppResult<CarrierProfile>? = null,
) : CarrierRepository {
    override suspend fun getMyCarrierApplication(): AppResult<CarrierProfile?> = AppResult.Success(carrier)

    override suspend fun applyCarrier(draft: NewCarrier): AppResult<CarrierProfile> =
        applyResult ?: AppResult.Success(
            CarrierProfile(id = "cr1", status = SellerStatus.NOT_STARTED, homeCommunityId = draft.homeCommunityId),
        )
}

@OptIn(ExperimentalCoroutinesApi::class)
class CarrierApplicationViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `with no application, carrier is null`() = runTest(dispatcher) {
        val vm = CarrierApplicationViewModel(FakeCarrierRepository(carrier = null), FakeAddressRepository())
        advanceUntilIdle()

        assertNull(vm.state.value.carrier)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `an existing application is loaded`() = runTest(dispatcher) {
        val vm = CarrierApplicationViewModel(FakeCarrierRepository(carrier = APPROVED_CARRIER), FakeAddressRepository())
        advanceUntilIdle()

        assertEquals(APPROVED_CARRIER, vm.state.value.carrier)
    }

    @Test fun `submitApplication sends the selected community and stores the resulting carrier`() = runTest(dispatcher) {
        val repo = FakeCarrierRepository(carrier = null)
        val vm = CarrierApplicationViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onCommunitySelected(KEPAYAN)
        assertTrue(vm.state.value.applicationForm.canSubmit)

        vm.submitApplication(); advanceUntilIdle()

        assertNotNull(vm.state.value.carrier)
        assertEquals("c1", vm.state.value.carrier?.homeCommunityId)
        assertFalse(vm.state.value.isSubmittingApplication)
    }

    @Test fun `submitApplication with no community selected is a no-op`() = runTest(dispatcher) {
        val vm = CarrierApplicationViewModel(FakeCarrierRepository(carrier = null), FakeAddressRepository())
        advanceUntilIdle()

        vm.submitApplication(); advanceUntilIdle()

        assertNull(vm.state.value.carrier)
        assertFalse(vm.state.value.isSubmittingApplication)
    }

    @Test fun `a failed application surfaces the error`() = runTest(dispatcher) {
        val repo = FakeCarrierRepository(
            carrier = null,
            applyResult = AppResult.Failure(AppError.Server("CARRIER_APPLICATION_EXISTS")),
        )
        val vm = CarrierApplicationViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onCommunitySelected(KEPAYAN)
        vm.submitApplication(); advanceUntilIdle()

        assertNull(vm.state.value.carrier)
        assertEquals(AppError.Server("CARRIER_APPLICATION_EXISTS"), vm.state.value.error)
    }

    @Test fun `onCommunityCleared resets the selection`() = runTest(dispatcher) {
        val vm = CarrierApplicationViewModel(FakeCarrierRepository(carrier = null), FakeAddressRepository())
        advanceUntilIdle()

        vm.onCommunitySelected(KEPAYAN)
        assertTrue(vm.state.value.applicationForm.canSubmit)

        vm.onCommunityCleared()
        assertFalse(vm.state.value.applicationForm.canSubmit)
        assertEquals("", vm.state.value.applicationForm.communityQuery)
    }
}
