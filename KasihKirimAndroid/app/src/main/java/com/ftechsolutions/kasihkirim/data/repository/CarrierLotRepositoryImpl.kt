package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.CarrierLotDto
import com.ftechsolutions.kasihkirim.domain.model.CarrierLot
import com.ftechsolutions.kasihkirim.domain.model.NewLot
import com.ftechsolutions.kasihkirim.domain.repository.CarrierLotRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Order
import io.github.jan.supabase.storage.storage
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.IOException
import java.util.UUID

private const val LOT_PHOTOS_BUCKET = "lot-photos"
private const val LOT_RECEIPTS_BUCKET = "lot-receipts"

class CarrierLotRepositoryImpl : CarrierLotRepository {

    private val tag = "CarrierLotRepository"

    override suspend fun listMyLots(carrierId: String): AppResult<List<CarrierLot>> = runCatchingResult {
        // lots_select's own RLS already scopes an unfiltered read to the
        // caller's own carrier_id plus any other carrier's ACTIVE rows --
        // the explicit eq() below is what actually narrows this to "my
        // lots" rather than relying on that second branch never matching.
        SupabaseClientProvider.client.postgrest.from("carrier_stock_lots")
            .select {
                filter { eq("carrier_id", carrierId) }
                order("created_at", Order.DESCENDING)
            }
            .decodeList<CarrierLotDto>()
            .map { it.toDomain() }
    }

    override suspend fun createLot(draft: NewLot): AppResult<String> = runCatchingResult {
        val json = SupabaseClientProvider.client.postgrest
            .rpc(
                "rpc_create_lot",
                buildJsonObject {
                    put("p_title", draft.title)
                    put("p_category_slug", draft.categorySlug)
                    put("p_qty_total", draft.qtyTotal)
                    put("p_cost_basis_sen", draft.costBasisSen)
                    put("p_cost_receipt_path", draft.costReceiptPath)
                    put("p_price_per_unit_sen", draft.pricePerUnitSen)
                    put("p_unit", draft.unit)
                    put("p_handling_flags", buildJsonArray {
                        draft.handlingFlags.forEach { add(JsonPrimitive(it.wire)) }
                    })
                    put("p_photo_paths", buildJsonArray {
                        draft.photoPaths.forEach { add(JsonPrimitive(it)) }
                    })
                    put("p_sell_by", draft.sellBy)
                },
            )
            .decodeAs<JsonObject>()
        json.getValue("lot_id").jsonPrimitive.content
    }

    override suspend fun attachLotToTrip(lotId: String, tripId: String): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.rpc(
            "rpc_attach_lot_to_trip",
            buildJsonObject {
                put("p_lot", lotId)
                put("p_trip", tripId)
            },
        )
        Unit
    }

    override suspend fun withdrawLot(lotId: String): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.rpc("rpc_withdraw_lot", buildJsonObject { put("p_lot", lotId) })
        Unit
    }

    override suspend fun uploadLotPhoto(photoBytes: ByteArray): AppResult<String> = runCatchingResult {
        uploadTo(LOT_PHOTOS_BUCKET, photoBytes)
    }

    override suspend fun uploadLotReceipt(photoBytes: ByteArray): AppResult<String> = runCatchingResult {
        uploadTo(LOT_RECEIPTS_BUCKET, photoBytes)
    }

    private suspend fun uploadTo(bucket: String, photoBytes: ByteArray): String {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: throw IllegalStateException("SESSION_EXPIRED")
        // First path segment must equal the uploader's own auth uid --
        // lot_photos_insert_owner/lot_receipts_insert_owner (0047) check
        // exactly that, the same convention product-images (0016) uses.
        val path = "$userId/${UUID.randomUUID()}.jpg"
        SupabaseClientProvider.client.storage.from(bucket).upload(path, photoBytes)
        return path
    }

    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "carrier lot call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toCarrierLotAppError())
        }
}

private fun Throwable.toCarrierLotAppError(): AppError = when {
    message?.contains("NOT_A_CARRIER", true) == true -> AppError.NotAuthorized
    message?.contains("SELLER_APPLICATION_REQUIRED", true) == true -> AppError.Server("SELLER_APPLICATION_REQUIRED")
    message?.contains("MARKETPLACE_NOT_ACTIVE", true) == true -> AppError.Server("MARKETPLACE_NOT_ACTIVE")
    message?.contains("MARKETPLACE_DISABLED", true) == true -> AppError.Server("MARKETPLACE_DISABLED")
    message?.contains("CATEGORY_NOT_PERMITTED", true) == true -> AppError.Server("CATEGORY_NOT_PERMITTED")
    message?.contains("CATEGORY_NOT_FOUND", true) == true -> AppError.Server("CATEGORY_NOT_FOUND")
    message?.contains("SELLER_NOT_ACTIVE", true) == true -> AppError.Server("SELLER_NOT_ACTIVE")
    message?.contains("SELLER_LICENCE_MISSING_OR_EXPIRED", true) == true ->
        AppError.Server("SELLER_LICENCE_MISSING_OR_EXPIRED")
    message?.contains("TITLE_TOO_SHORT", true) == true -> AppError.Server("TITLE_TOO_SHORT")
    message?.contains("INVALID_QUANTITY", true) == true -> AppError.Server("INVALID_QUANTITY")
    message?.contains("INVALID_AMOUNT", true) == true -> AppError.Server("INVALID_AMOUNT")
    message?.contains("COST_RECEIPT_REQUIRED", true) == true -> AppError.Server("COST_RECEIPT_REQUIRED")
    message?.contains("LOT_HISTORY_REQUIRED", true) == true -> AppError.Server("LOT_HISTORY_REQUIRED")
    message?.contains("LOT_VALUE_EXCEEDS_LIMIT", true) == true -> AppError.Server("LOT_VALUE_EXCEEDS_LIMIT")
    message?.contains("FLOAT_LIMIT_EXCEEDED", true) == true -> AppError.Server("FLOAT_LIMIT_EXCEEDED")
    message?.contains("LOT_NOT_FOUND", true) == true -> AppError.Server("LOT_NOT_FOUND")
    message?.contains("LOT_NOT_DRAFT", true) == true -> AppError.Server("LOT_NOT_DRAFT")
    message?.contains("LOT_NOT_WITHDRAWABLE", true) == true -> AppError.Server("LOT_NOT_WITHDRAWABLE")
    message?.contains("TRIP_NOT_FOUND", true) == true -> AppError.Server("TRIP_NOT_FOUND")
    message?.contains("TRIP_NOT_BOARDING", true) == true -> AppError.Server("TRIP_NOT_BOARDING")
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
