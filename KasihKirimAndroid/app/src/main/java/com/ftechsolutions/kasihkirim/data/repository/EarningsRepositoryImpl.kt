package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.domain.model.BankAccount
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.PayeeType
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest
import com.ftechsolutions.kasihkirim.domain.model.PayoutStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.IOException

class EarningsRepositoryImpl : EarningsRepository {

    private val tag = "EarningsRepository"

    override suspend fun myEarnings(): AppResult<Earnings> =
        try {
            // rpc_my_earnings takes no parameters, but the reified
            // rpc(function, parameters: T) overload isn't in the pinned
            // supabase-bom 3.5.0 -- only rpc(function, JsonObject) exists
            // there (same constraint as KirimRepositoryImpl/AddressRepositoryImpl),
            // so an empty JsonObject stands in for "no arguments".
            val json = SupabaseClientProvider.client.postgrest
                .rpc("rpc_my_earnings", buildJsonObject {})
                .decodeAs<JsonObject>()
            AppResult.Success(json.toEarnings())
        } catch (t: Throwable) {
            SafeLog.e(tag, "earnings call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toEarningsAppError())
        }

    override suspend fun myBankAccounts(): AppResult<List<BankAccount>> =
        try {
            val rows = SupabaseClientProvider.client.postgrest
                .rpc("rpc_my_bank_accounts", buildJsonObject {})
                .decodeAs<JsonArray>()
            AppResult.Success(rows.map { (it as JsonObject).toBankAccount() })
        } catch (t: Throwable) {
            SafeLog.e(tag, "bank account list failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toEarningsAppError())
        }

    override suspend fun addBankAccount(bankCode: String, accountNo: String, holderName: String): AppResult<BankAccount> =
        try {
            val json = SupabaseClientProvider.client.postgrest
                .rpc(
                    "rpc_add_bank_account",
                    buildJsonObject {
                        put("p_bank_code", bankCode)
                        put("p_account_no", accountNo)
                        put("p_holder_name", holderName)
                    },
                )
                .decodeAs<JsonObject>()
            AppResult.Success(
                BankAccount(
                    id = json.getValue("id").jsonPrimitive.content,
                    bankCode = json.getValue("bank_code").jsonPrimitive.content,
                    accountNoLast4 = json.getValue("account_no_last4").jsonPrimitive.content,
                    holderName = json.getValue("holder_name").jsonPrimitive.content,
                    verifiedAt = null,
                    createdAt = "",
                ),
            )
        } catch (t: Throwable) {
            SafeLog.e(tag, "add bank account failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toEarningsAppError())
        }

    override suspend fun requestWithdrawal(payeeType: PayeeType, bankAccountId: String, amountSen: Long): AppResult<Unit> =
        try {
            SupabaseClientProvider.client.postgrest.rpc(
                "rpc_request_withdrawal",
                buildJsonObject {
                    put("p_payee_type", payeeType.wire)
                    put("p_bank_account_id", bankAccountId)
                    put("p_amount_sen", amountSen)
                },
            )
            AppResult.Success(Unit)
        } catch (t: Throwable) {
            SafeLog.e(tag, "withdrawal request failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toEarningsAppError())
        }

    override suspend fun myPayouts(): AppResult<List<PayoutRequest>> =
        try {
            val rows = SupabaseClientProvider.client.postgrest
                .rpc("rpc_my_payouts", buildJsonObject {})
                .decodeAs<JsonArray>()
            AppResult.Success(rows.map { (it as JsonObject).toPayoutRequest() })
        } catch (t: Throwable) {
            SafeLog.e(tag, "payout history failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toEarningsAppError())
        }
}

private fun JsonObject.toBankAccount() = BankAccount(
    id = getValue("id").jsonPrimitive.content,
    bankCode = getValue("bank_code").jsonPrimitive.content,
    accountNoLast4 = getValue("account_no_last4").jsonPrimitive.content,
    holderName = getValue("holder_name").jsonPrimitive.content,
    verifiedAt = this["verified_at"]?.stringOrNull(),
    createdAt = getValue("created_at").jsonPrimitive.content,
)

private fun JsonObject.toPayoutRequest() = PayoutRequest(
    id = getValue("id").jsonPrimitive.content,
    payeeType = getValue("payee_type").jsonPrimitive.content,
    amountSen = Sen(getValue("amount_sen").jsonPrimitive.long),
    status = PayoutStatus.fromWire(getValue("status").jsonPrimitive.content) ?: PayoutStatus.REQUESTED,
    bankCode = getValue("bank_code").jsonPrimitive.content,
    accountNoLast4 = getValue("account_no_last4").jsonPrimitive.content,
    requestedAt = getValue("requested_at").jsonPrimitive.content,
    paidAt = this["paid_at"]?.stringOrNull(),
    failureReason = this["failure_reason"]?.stringOrNull(),
)

// RETURNS TABLE(...) always includes every column as a key, even when its
// value is SQL NULL -- unlike rpc_my_earnings' own jsonb_build_object calls,
// which omit a key entirely instead of ever writing JSON null. A JsonNull IS
// a JsonPrimitive (its .content is the literal string "null"), so a bare
// `?.jsonPrimitive?.content` would silently turn a real NULL into that
// string. Mirrors KirimRepositoryImpl's own longOrNull() for the same reason.
private fun JsonElement.stringOrNull(): String? =
    (this as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content

private fun JsonObject.toEarnings() = Earnings(
    availableSen = Sen(getValue("available_sen").jsonPrimitive.long),
    pendingSen = Sen(getValue("pending_sen").jsonPrimitive.long),
    codHeldSen = this["cod_held_sen"]?.jsonPrimitive?.long?.let(::Sen),
    floatLimitSen = this["float_limit_sen"]?.jsonPrimitive?.long?.let(::Sen),
    sellerAvailableSen = this["seller_available_sen"]?.jsonPrimitive?.long?.let(::Sen),
    sellerPendingSen = this["seller_pending_sen"]?.jsonPrimitive?.long?.let(::Sen),
)

private fun Throwable.toEarningsAppError(): AppError = when {
    // rpc_add_bank_account / rpc_request_withdrawal's own named RAISE
    // EXCEPTION codes (0042_carrier_seller_payouts.sql).
    message?.contains("NOT_A_PAYEE", true) == true -> AppError.Server("NOT_A_PAYEE")
    message?.contains("INVALID_BANK_CODE", true) == true -> AppError.Server("INVALID_BANK_CODE")
    message?.contains("INVALID_HOLDER_NAME", true) == true -> AppError.Server("INVALID_HOLDER_NAME")
    message?.contains("INVALID_ACCOUNT_NO", true) == true -> AppError.Server("INVALID_ACCOUNT_NO")
    message?.contains("BANK_ACCOUNT_ENC_KEY_NOT_CONFIGURED", true) == true ->
        AppError.Server("BANK_ACCOUNT_ENC_KEY_NOT_CONFIGURED")
    message?.contains("INVALID_PAYEE_TYPE", true) == true -> AppError.Server("INVALID_PAYEE_TYPE")
    message?.contains("INVALID_AMOUNT", true) == true -> AppError.Server("INVALID_AMOUNT")
    message?.contains("NOT_A_CARRIER", true) == true -> AppError.Server("NOT_A_CARRIER")
    message?.contains("NOT_A_SELLER", true) == true -> AppError.Server("NOT_A_SELLER")
    message?.contains("BANK_ACCOUNT_NOT_FOUND", true) == true -> AppError.Server("BANK_ACCOUNT_NOT_FOUND")
    message?.contains("INSUFFICIENT_BALANCE", true) == true -> AppError.Server("INSUFFICIENT_BALANCE")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
