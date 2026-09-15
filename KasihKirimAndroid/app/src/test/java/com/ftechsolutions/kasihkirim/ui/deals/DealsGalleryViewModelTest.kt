package com.ftechsolutions.kasihkirim.ui.deals

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.DealCampaign
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.DealsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val DEAL = DealCampaign(
    id = "d1", title = "Tawaran Bayam", subtitle = "10% off", imagePath = "deal-banners/bayam.jpg",
    productId = "p1", productTitle = "Bayam", priceSen = Sen(500), unit = "kg",
)

private class FakeDealsRepository(
    var result: AppResult<List<DealCampaign>> = AppResult.Success(listOf(DEAL)),
) : DealsRepository {
    var calls = 0
    override suspend fun listActiveDeals(): AppResult<List<DealCampaign>> {
        calls++
        return result
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class DealsGalleryViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `deals load on init`() = runTest(dispatcher) {
        val vm = DealsGalleryViewModel(FakeDealsRepository())
        advanceUntilIdle()

        assertEquals(listOf(DEAL), vm.state.value.deals)
        assertFalse(vm.state.value.isLoading)
        assertNull(vm.state.value.error)
    }

    @Test fun `a failed load surfaces the error and leaves the list empty`() = runTest(dispatcher) {
        val repo = FakeDealsRepository(result = AppResult.Failure(AppError.Network))
        val vm = DealsGalleryViewModel(repo)
        advanceUntilIdle()

        assertTrue(vm.state.value.deals.isEmpty())
        assertEquals(AppError.Network, vm.state.value.error)
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `load can be retried after a failure`() = runTest(dispatcher) {
        val repo = FakeDealsRepository(result = AppResult.Failure(AppError.Network))
        val vm = DealsGalleryViewModel(repo)
        advanceUntilIdle()
        assertTrue(vm.state.value.deals.isEmpty())

        repo.result = AppResult.Success(listOf(DEAL))
        vm.load()
        advanceUntilIdle()

        assertEquals(listOf(DEAL), vm.state.value.deals)
        assertNull(vm.state.value.error)
        assertEquals(2, repo.calls)
    }
}
