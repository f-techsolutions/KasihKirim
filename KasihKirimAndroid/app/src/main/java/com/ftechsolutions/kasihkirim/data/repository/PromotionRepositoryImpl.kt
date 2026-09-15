package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.domain.model.CreatedPromotion
import com.ftechsolutions.kasihkirim.domain.model.MyPromotion
import com.ftechsolutions.kasihkirim.domain.model.MyPromotions
import com.ftechsolutions.kasihkirim.domain.model.OpenedPromotion
import com.ftechsolutions.kasihkirim.domain.model.PromotionSubjectType
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.repository.PromotionRepository
import io.github.jan.supabase.postgrest.postgrest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.IOException

class PromotionRepositoryImpl : PromotionRepository {

    private val tag = "PromotionRepository"

    override suspend fun createPromotion(
        subjectType: PromotionSubjectType,
        subjectId: String,
    ): AppResult<CreatedPromotion> =
        try {
            val json = SupabaseClientProvider.client.postgrest
                .rpc(
                    "rpc_create_promotion",
                    buildJsonObject {
                        put("p_subject_type", subjectType.wire)
                        put("p_subject_id", subjectId)
                    },
                )
                .decodeAs<JsonObject>()
            AppResult.Success(
                CreatedPromotion(
                    id = json.getValue("id").jsonPrimitive.content,
                    code = json.getValue("code").jsonPrimitive.content,
                    subjectType = subjectType,
                    subjectId = json.getValue("subject_id").jsonPrimitive.content,
                    shareLink = json.getValue("share_link").jsonPrimitive.content,
                ),
            )
        } catch (t: Throwable) {
            SafeLog.e(tag, "create promotion failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toPromotionAppError())
        }

    override suspend fun openPromotion(code: String): AppResult<OpenedPromotion> =
        try {
            val json = SupabaseClientProvider.client.postgrest
                .rpc("rpc_open_promotion", buildJsonObject { put("p_code", code) })
                .decodeAs<JsonObject>()
            AppResult.Success(json.toOpenedPromotion())
        } catch (t: Throwable) {
            SafeLog.e(tag, "open promotion failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toPromotionAppError())
        }

    override suspend fun myPromotions(): AppResult<MyPromotions> =
        try {
            val json = SupabaseClientProvider.client.postgrest
                .rpc("rpc_my_promotions", buildJsonObject {})
                .decodeAs<JsonObject>()
            AppResult.Success(
                MyPromotions(
                    promotions = (json["promotions"] as? JsonArray)
                        ?.map { (it as JsonObject).toMyPromotion() }
                        ?: emptyList(),
                    availableSen = Sen(json.getValue("available_sen").jsonPrimitive.long),
                ),
            )
        } catch (t: Throwable) {
            SafeLog.e(tag, "my promotions failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toPromotionAppError())
        }
}

private fun JsonObject.toOpenedPromotion(): OpenedPromotion {
    val found = getValue("found").jsonPrimitive.boolean
    if (!found) return OpenedPromotion(false, null, null, null, null, null)
    val subject = this["subject"] as? JsonObject
    return OpenedPromotion(
        found = true,
        subjectType = this["subject_type"]?.jsonPrimitive?.content
            ?.let { wire -> PromotionSubjectType.entries.firstOrNull { it.wire == wire } },
        subjectId = this["subject_id"]?.jsonPrimitive?.content,
        title = subject?.get("title")?.jsonPrimitive?.content,
        priceSen = subject?.get("price_sen")?.jsonPrimitive?.long?.let(::Sen),
        sellerName = subject?.get("seller_name")?.jsonPrimitive?.content,
    )
}

private fun JsonObject.toMyPromotion() = MyPromotion(
    id = getValue("id").jsonPrimitive.content,
    code = getValue("code").jsonPrimitive.content,
    subjectType = getValue("subject_type").jsonPrimitive.content
        .let { wire -> PromotionSubjectType.entries.firstOrNull { it.wire == wire } ?: PromotionSubjectType.PRODUCT },
    subjectId = getValue("subject_id").jsonPrimitive.content,
    subjectLabel = this["subject_label"]?.jsonPrimitive?.content,
    isActive = getValue("is_active").jsonPrimitive.boolean,
    clickCount = getValue("click_count").jsonPrimitive.int,
    pendingSen = Sen(getValue("pending_sen").jsonPrimitive.long),
    settledSen = Sen(getValue("settled_sen").jsonPrimitive.long),
    createdAt = getValue("created_at").jsonPrimitive.content,
)

private fun Throwable.toPromotionAppError(): AppError = when {
    // rpc_create_promotion / rpc_open_promotion's own named RAISE EXCEPTION
    // codes (0045_kongsi_untung_promotions.sql).
    message?.contains("KONGSI_UNTUNG_DISABLED", true) == true -> AppError.Server("KONGSI_UNTUNG_DISABLED")
    message?.contains("INVALID_SUBJECT_TYPE", true) == true -> AppError.Server("INVALID_SUBJECT_TYPE")
    message?.contains("PRODUCT_NOT_FOUND", true) == true -> AppError.Server("PRODUCT_NOT_FOUND")
    message?.contains("SELLER_NOT_FOUND", true) == true -> AppError.Server("SELLER_NOT_FOUND")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
