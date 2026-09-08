package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.KirimRequestDto
import com.ftechsolutions.kasihkirim.domain.model.KirimCreated
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.KirimSubmission
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.IOException

private const val KIRIM_COLUMNS =
    "id,reference_code,kirim_type,status,item_description,est_weight_grams," +
        "origin_node_id,dest_node_id,budget_cap_sen,delivery_fee_sen,commission_sen,created_at"

class KirimRepositoryImpl : KirimRepository {

    private val tag = "KirimRepository"

    override suspend fun quoteKirim(draft: KirimDraft): AppResult<KirimQuote> =
        try {
            val json = SupabaseClientProvider.client.postgrest
                .rpc(
                    "rpc_quote_kirim",
                    buildJsonObject {
                        put("p_kirim_type", draft.kirimType.wire)
                        put("p_category_slug", draft.category.slug)
                        put("p_est_weight_grams", draft.estWeightGrams)
                        put("p_origin_node", draft.originNodeId)
                        put("p_dest_node", draft.destNodeId)
                        put("p_budget_cap_sen", draft.budgetSen)
                    },
                )
                .decodeAs<JsonObject>()
            AppResult.Success(json.toKirimQuote())
        } catch (t: Throwable) {
            SafeLog.e(tag, "quote call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toKirimAppError())
        }

    override suspend fun createKirim(submission: KirimSubmission): AppResult<KirimCreated> =
        try {
            val json = SupabaseClientProvider.client.postgrest
                .rpc(
                    "rpc_create_kirim",
                    buildJsonObject {
                        put("p_quote_id", submission.quoteId)
                        put("p_item_description", submission.itemDescription)
                        put("p_dest_address_id", submission.destAddressId)
                        submission.originAddressId?.let { put("p_origin_address_id", it) }
                        submission.declaredValueSen?.let { put("p_declared_value_sen", it) }
                    },
                )
                .decodeAs<JsonObject>()
            AppResult.Success(json.toKirimCreated())
        } catch (t: Throwable) {
            SafeLog.e(tag, "create call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toKirimAppError())
        }

    override suspend fun listBoard(): AppResult<List<KirimSummary>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("kirim_requests")
            .select(columns = Columns.raw(KIRIM_COLUMNS)) {
                filter {
                    eq("status", "POSTED")
                    eq("visibility", "board")
                    exact("deleted_at", null)
                }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<KirimRequestDto>()
            .map { it.toDomain() }
    }

    override suspend fun listMyKirims(): AppResult<List<KirimSummary>> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        SupabaseClientProvider.client.postgrest.from("kirim_requests")
            .select(columns = Columns.raw(KIRIM_COLUMNS)) {
                filter {
                    eq("requester_id", userId)
                    exact("deleted_at", null)
                }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<KirimRequestDto>()
            .map { it.toDomain() }
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "kirim call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toKirimAppError())
        }
}

private fun JsonObject.toKirimQuote() = KirimQuote(
    quoteId = getValue("quote_id").jsonPrimitive.content,
    expiresAt = getValue("expires_at").jsonPrimitive.content,
    corridorKm = getValue("corridor_km").jsonPrimitive.double,
    corridorBand = getValue("corridor_band").jsonPrimitive.content,
    goodsBudgetSen = Sen(getValue("goods_budget_sen").jsonPrimitive.long),
    deliveryFeeSen = Sen(getValue("delivery_fee_sen").jsonPrimitive.long),
    commissionSen = Sen(getValue("commission_sen").jsonPrimitive.long),
    orderTotalSen = Sen(getValue("order_total_sen").jsonPrimitive.long),
    carrierEarningSen = Sen(getValue("carrier_earning_sen").jsonPrimitive.long),
    pricingRuleVersion = getValue("pricing_rule_version").jsonPrimitive.int,
)

private fun JsonObject.toKirimCreated() = KirimCreated(
    kirimId = getValue("kirim_id").jsonPrimitive.content,
    referenceCode = getValue("reference_code").jsonPrimitive.content,
    expiresAt = getValue("expires_at").jsonPrimitive.content,
)

/** rpc_quote_kirim/rpc_create_kirim's named RAISE EXCEPTION codes
 *  (0005_rpc_surface.sql, 0012_kirim_trip_creation.sql), mapped the same way
 *  AuthRepositoryImpl/AddressRepositoryImpl map theirs. */
private fun Throwable.toKirimAppError(): AppError = when {
    message?.contains("UNAUTHENTICATED", true) == true -> AppError.SessionExpired
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    message?.contains("BUDGET_CAP_EXCEEDED", true) == true -> AppError.Server("BUDGET_CAP_EXCEEDED")
    message?.contains("CATEGORY_NOT_FOUND", true) == true -> AppError.Server("CATEGORY_NOT_FOUND")
    message?.contains("QUOTE_NOT_FOUND", true) == true -> AppError.Server("QUOTE_NOT_FOUND")
    message?.contains("QUOTE_ALREADY_CONSUMED", true) == true -> AppError.Server("QUOTE_ALREADY_CONSUMED")
    message?.contains("QUOTE_EXPIRED", true) == true -> AppError.Server("QUOTE_EXPIRED")
    message?.contains("ADDRESS_NOT_FOUND", true) == true -> AppError.Server("ADDRESS_NOT_FOUND")
    message?.contains("ORIGIN_ADDRESS_REQUIRED", true) == true -> AppError.Server("ORIGIN_ADDRESS_REQUIRED")
    message?.contains("BELI_REQUIRES_BUDGET", true) == true -> AppError.Server("BELI_REQUIRES_BUDGET")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
