package com.ftechsolutions.kasihkirim.ui.addresses

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val KAMPUNG_A = Community(id = "c1", name = "Kampung A", type = "kampung", district = "Beluran", state = "Sabah")

private class FakeAddressRepository(
    var addresses: List<Address> = emptyList(),
    var communities: List<Community> = listOf(KAMPUNG_A),
    var createResult: AppResult<Address>? = null,
) : AddressRepository {
    var createCalls = 0

    override suspend fun listAddresses(): AppResult<List<Address>> = AppResult.Success(addresses)

    override suspend fun createAddress(draft: NewAddress): AppResult<Address> {
        createCalls++
        return createResult ?: AppResult.Success(
            Address(
                id = "new",
                label = draft.label,
                recipientName = draft.recipientName,
                recipientPhone = draft.recipientPhone,
                community = KAMPUNG_A,
                landmarkNote = draft.landmarkNote,
                isDefault = false,
            ),
        )
    }

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> =
        AppResult.Success(communities.filter { query.isBlank() || it.name.contains(query, ignoreCase = true) })
}

@OptIn(ExperimentalCoroutinesApi::class)
class AddressesViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `loads addresses on construction`() = runTest(dispatcher) {
        val repo = FakeAddressRepository(addresses = listOf(
            Address("a1", "Rumah", "Aisyah", "+60123456789", KAMPUNG_A, "Sebelah kedai runcit", true),
        ))
        val vm = AddressesViewModel(repo)
        advanceUntilIdle()
        assertEquals(1, vm.state.value.addresses.size)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `submit is blocked until every required field is valid`() = runTest(dispatcher) {
        val vm = AddressesViewModel(FakeAddressRepository()); advanceUntilIdle()
        assertFalse(vm.state.value.form.canSubmit)

        vm.onLabelChange("Rumah")
        vm.onRecipientNameChange("Aisyah")
        assertFalse("phone still missing", vm.state.value.form.canSubmit)

        vm.onRecipientPhoneChange("0123456789")
        assertFalse("phone missing +60 prefix", vm.state.value.form.canSubmit)

        vm.onRecipientPhoneChange("+60123456789")
        vm.onLandmarkNoteChange("Sebelah kedai runcit")
        assertFalse("community not selected", vm.state.value.form.canSubmit)

        vm.onCommunitySelected(KAMPUNG_A)
        assertTrue(vm.state.value.form.canSubmit)
    }

    @Test fun `successful submit prepends the new address and clears the form`() = runTest(dispatcher) {
        val repo = FakeAddressRepository()
        val vm = AddressesViewModel(repo); advanceUntilIdle()
        vm.onLabelChange("Rumah")
        vm.onRecipientNameChange("Aisyah")
        vm.onRecipientPhoneChange("+60123456789")
        vm.onLandmarkNoteChange("Sebelah kedai runcit")
        vm.onCommunitySelected(KAMPUNG_A)

        vm.submit(); advanceUntilIdle()

        assertEquals(1, repo.createCalls)
        assertEquals(1, vm.state.value.addresses.size)
        assertEquals("", vm.state.value.form.label)
        assertFalse(vm.state.value.isSubmitting)
    }

    @Test fun `submit is a no-op while the form is invalid`() = runTest(dispatcher) {
        val repo = FakeAddressRepository()
        val vm = AddressesViewModel(repo); advanceUntilIdle()

        vm.submit(); advanceUntilIdle()

        assertEquals(0, repo.createCalls)
    }
}
