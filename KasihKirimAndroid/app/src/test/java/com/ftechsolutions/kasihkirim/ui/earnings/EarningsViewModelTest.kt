package com.ftechsolutions.kasihkirim.ui.earnings

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private class FakeEarningsRepository(
    var result: AppResult<Earnings> = AppResult.Success(
        Earnings(availableSen = Sen(5000), pendingSen = Sen(1200), codHeldSen = Sen(800), floatLimitSen = Sen(20000)),
    ),
) : EarningsRepository {
    var calls = 0
    override suspend fun myEarnings(): AppResult<Earnings> {
        calls++
        return result
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class EarningsViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `loads earnings on creation`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository()
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        assertEquals(1, repo.calls)
        assertFalse(vm.state.value.isLoading)
        assertEquals(Sen(5000), vm.state.value.earnings?.availableSen)
        assertNull(vm.state.value.error)
    }

    @Test fun `a non-carrier caller surfaces zeroed earnings with no cod or float fields`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(
            result = AppResult.Success(Earnings(Sen.ZERO, Sen.ZERO, codHeldSen = null, floatLimitSen = null)),
        )
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        val earnings = vm.state.value.earnings!!
        assertEquals(Sen.ZERO, earnings.availableSen)
        assertNull(earnings.codHeldSen)
        assertNull(earnings.floatLimitSen)
    }

    @Test fun `a failed load surfaces the error and clears isLoading`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(result = AppResult.Failure(AppError.Network))
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        assertNull(vm.state.value.earnings)
        assertFalse(vm.state.value.isLoading)
        assertEquals(AppError.Network, vm.state.value.error)
    }

    @Test fun `load can be retried after a failure`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(result = AppResult.Failure(AppError.Network))
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()
        assertNotNull(vm.state.value.error)

        repo.result = AppResult.Success(Earnings(Sen(100), Sen.ZERO, codHeldSen = null, floatLimitSen = null))
        vm.load(); advanceUntilIdle()

        assertEquals(2, repo.calls)
        assertNull(vm.state.value.error)
        assertEquals(Sen(100), vm.state.value.earnings?.availableSen)
    }
}
