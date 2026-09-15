package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.BankAccount
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.PayeeType
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest

/**
 * rpc_my_earnings (Phase 7 / §31) was the sole read here until Phase 1's
 * third item gave this balance an actual withdrawal path (0042
 * _carrier_seller_payouts.sql) -- rpc_admin_mark_payout_paid is the only
 * place that write ever reaches the ledger, never this repository.
 */
interface EarningsRepository {
    suspend fun myEarnings(): AppResult<Earnings>

    /** rpc_my_bank_accounts. */
    suspend fun myBankAccounts(): AppResult<List<BankAccount>>

    /** rpc_add_bank_account. Returns the new account (last-4 only --
     *  the full number is never sent back, only encrypted server-side). */
    suspend fun addBankAccount(bankCode: String, accountNo: String, holderName: String): AppResult<BankAccount>

    /** rpc_request_withdrawal. */
    suspend fun requestWithdrawal(payeeType: PayeeType, bankAccountId: String, amountSen: Long): AppResult<Unit>

    /** rpc_my_payouts. */
    suspend fun myPayouts(): AppResult<List<PayoutRequest>>
}
