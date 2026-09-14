package com.ftechsolutions.kasihkirim.ui.earnings

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BankAccount
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.PayeeType
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest
import com.ftechsolutions.kasihkirim.domain.model.PayoutStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val A_BANK_ACCOUNT = BankAccount(
    id = "b1", bankCode = "MBB", accountNoLast4 = "1234", holderName = "Rahman",
    verifiedAt = null, createdAt = "2026-09-10T00:00:00Z",
)

private val A_PAYOUT = PayoutRequest(
    id = "p1", payeeType = "carrier", amountSen = Sen(5000), status = PayoutStatus.REQUESTED,
    bankCode = "MBB", accountNoLast4 = "1234", requestedAt = "2026-09-10T00:00:00Z",
    paidAt = null, failureReason = null,
)

private class FakeEarningsRepository(
    var earningsResult: AppResult<Earnings> = AppResult.Success(
        Earnings(availableSen = Sen(5000), pendingSen = Sen(1200), codHeldSen = Sen(800), floatLimitSen = Sen(20000)),
    ),
    var bankAccountsResult: AppResult<List<BankAccount>> = AppResult.Success(emptyList()),
    var payoutsResult: AppResult<List<PayoutRequest>> = AppResult.Success(emptyList()),
    var addBankAccountResult: AppResult<BankAccount> = AppResult.Success(A_BANK_ACCOUNT),
    var requestWithdrawalResult: AppResult<Unit> = AppResult.Success(Unit),
) : EarningsRepository {
    var calls = 0
    var addBankAccountCalls = mutableListOf<Triple<String, String, String>>()
    var withdrawalCalls = mutableListOf<Triple<PayeeType, String, Long>>()

    override suspend fun myEarnings(): AppResult<Earnings> {
        calls++
        return earningsResult
    }

    override suspend fun myBankAccounts(): AppResult<List<BankAccount>> = bankAccountsResult

    override suspend fun addBankAccount(bankCode: String, accountNo: String, holderName: String): AppResult<BankAccount> {
        addBankAccountCalls += Triple(bankCode, accountNo, holderName)
        return addBankAccountResult
    }

    override suspend fun requestWithdrawal(payeeType: PayeeType, bankAccountId: String, amountSen: Long): AppResult<Unit> {
        withdrawalCalls += Triple(payeeType, bankAccountId, amountSen)
        return requestWithdrawalResult
    }

    override suspend fun myPayouts(): AppResult<List<PayoutRequest>> = payoutsResult
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
            earningsResult = AppResult.Success(Earnings(Sen.ZERO, Sen.ZERO, codHeldSen = null, floatLimitSen = null)),
        )
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        val earnings = vm.state.value.earnings!!
        assertEquals(Sen.ZERO, earnings.availableSen)
        assertNull(earnings.codHeldSen)
        assertNull(earnings.floatLimitSen)
    }

    @Test fun `a failed load surfaces the error and clears isLoading`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(earningsResult = AppResult.Failure(AppError.Network))
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        assertNull(vm.state.value.earnings)
        assertFalse(vm.state.value.isLoading)
        assertEquals(AppError.Network, vm.state.value.error)
    }

    @Test fun `load can be retried after a failure`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(earningsResult = AppResult.Failure(AppError.Network))
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()
        assertNotNull(vm.state.value.error)

        repo.earningsResult = AppResult.Success(Earnings(Sen(100), Sen.ZERO, codHeldSen = null, floatLimitSen = null))
        vm.load(); advanceUntilIdle()

        assertEquals(2, repo.calls)
        assertNull(vm.state.value.error)
        assertEquals(Sen(100), vm.state.value.earnings?.availableSen)
    }

    @Test fun `bank accounts and payouts load alongside earnings`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(
            bankAccountsResult = AppResult.Success(listOf(A_BANK_ACCOUNT)),
            payoutsResult = AppResult.Success(listOf(A_PAYOUT)),
        )
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        assertEquals(listOf(A_BANK_ACCOUNT), vm.state.value.bankAccounts)
        assertEquals(listOf(A_PAYOUT), vm.state.value.payouts)
    }

    @Test fun `adding a bank account reloads and clears the busy flag`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository()
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()
        val loadsAfterInit = repo.calls

        vm.addBankAccount("MBB", "9876543210", "Rahman"); advanceUntilIdle()

        assertEquals(listOf(Triple("MBB", "9876543210", "Rahman")), repo.addBankAccountCalls)
        assertTrue("a successful add reloads earnings/accounts/payouts", repo.calls > loadsAfterInit)
        assertFalse(vm.state.value.isSubmitting)
    }

    @Test fun `a failed bank account add surfaces the error and clears the busy flag`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(addBankAccountResult = AppResult.Failure(AppError.Server("INVALID_ACCOUNT_NO")))
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        vm.addBankAccount("MBB", "12", "Rahman"); advanceUntilIdle()

        assertEquals(AppError.Server("INVALID_ACCOUNT_NO"), vm.state.value.error)
        assertFalse(vm.state.value.isSubmitting)
    }

    @Test fun `requesting a withdrawal carries the payee type, bank account and amount through`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository()
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()
        val loadsAfterInit = repo.calls

        vm.requestWithdrawal(PayeeType.CARRIER, "b1", 5000); advanceUntilIdle()

        assertEquals(listOf(Triple(PayeeType.CARRIER, "b1", 5000L)), repo.withdrawalCalls)
        assertTrue("a successful request reloads earnings/accounts/payouts", repo.calls > loadsAfterInit)
        assertFalse(vm.state.value.isSubmitting)
    }

    @Test fun `a failed withdrawal request surfaces the error and clears the busy flag`() = runTest(dispatcher) {
        val repo = FakeEarningsRepository(requestWithdrawalResult = AppResult.Failure(AppError.Server("INSUFFICIENT_BALANCE")))
        val vm = EarningsViewModel(repo)
        advanceUntilIdle()

        vm.requestWithdrawal(PayeeType.CARRIER, "b1", 999999); advanceUntilIdle()

        assertEquals(AppError.Server("INSUFFICIENT_BALANCE"), vm.state.value.error)
        assertFalse(vm.state.value.isSubmitting)
    }
}
