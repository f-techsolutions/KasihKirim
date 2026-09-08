package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.IOException

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

/** rpc_quote_kirim's named RAISE EXCEPTION codes (0005_rpc_surface.sql),
 *  mapped the same way AuthRepositoryImpl/AddressRepositoryImpl map theirs. */
private fun Throwable.toKirimAppError(): AppError = when {
    message?.contains("UNAUTHENTICATED", true) == true -> AppError.SessionExpired
    message?.contains("BUDGET_CAP_EXCEEDED", true) == true -> AppError.Server("BUDGET_CAP_EXCEEDED")
    message?.contains("CATEGORY_NOT_FOUND", true) == true -> AppError.Server("CATEGORY_NOT_FOUND")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
