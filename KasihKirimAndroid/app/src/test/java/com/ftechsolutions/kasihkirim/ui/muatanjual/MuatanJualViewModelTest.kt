package com.ftechsolutions.kasihkirim.ui.muatanjual

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val LISTING = MuatanJualListing(
    id = "l1", carrierId = "c1", title = "Sayur Beluran",
    handlingFlags = listOf(HandlingFlag.PERISHABLE), unit = "kg",
    pricePerUnitSen = Sen(250), qtyAvailable = 40.0, sellBy = "2026-09-10T00:00:00Z",
)

private class FakeMuatanJualRepository(
    var result: AppResult<List<MuatanJualListing>> = AppResult.Success(listOf(LISTING)),
) : MuatanJualRepository {
    var calls = 0
    override suspend fun listLots(): AppResult<List<MuatanJualListing>> {
        calls++
        return result
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class MuatanJualViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `loads listings on creation`() = runTest(dispatcher) {
        val repo = FakeMuatanJualRepository()
        val vm = MuatanJualViewModel(repo)
        advanceUntilIdle()

        assertEquals(1, repo.calls)
        assertFalse(vm.state.value.isLoading)
        assertEquals(1, vm.state.value.listings.size)
        assertEquals("Sayur Beluran", vm.state.value.listings.first().title)
        assertNull(vm.state.value.error)
    }

    @Test fun `an empty marketplace surfaces an empty list, not an error`() = runTest(dispatcher) {
        val vm = MuatanJualViewModel(FakeMuatanJualRepository(result = AppResult.Success(emptyList())))
        advanceUntilIdle()

        assertTrue(vm.state.value.listings.isEmpty())
        assertNull(vm.state.value.error)
    }

    @Test fun `a failed load surfaces the error and clears isLoading`() = runTest(dispatcher) {
        val vm = MuatanJualViewModel(FakeMuatanJualRepository(result = AppResult.Failure(AppError.Network)))
        advanceUntilIdle()

        assertTrue(vm.state.value.listings.isEmpty())
        assertFalse(vm.state.value.isLoading)
        assertEquals(AppError.Network, vm.state.value.error)
    }

    @Test fun `load can be retried after a failure`() = runTest(dispatcher) {
        val repo = FakeMuatanJualRepository(result = AppResult.Failure(AppError.Network))
        val vm = MuatanJualViewModel(repo)
        advanceUntilIdle()
        assertNotNull(vm.state.value.error)

        repo.result = AppResult.Success(listOf(LISTING))
        vm.load(); advanceUntilIdle()

        assertEquals(2, repo.calls)
        assertNull(vm.state.value.error)
        assertEquals(1, vm.state.value.listings.size)
    }
}
