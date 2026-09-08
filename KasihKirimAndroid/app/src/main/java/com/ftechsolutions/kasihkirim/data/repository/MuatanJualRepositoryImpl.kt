package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.LotListingDto
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import java.io.IOException

private const val LOT_COLUMNS = "id,carrier_id,title,handling_flags,unit,price_per_unit_sen,qty_available,sell_by"

class MuatanJualRepositoryImpl : MuatanJualRepository {

    private val tag = "MuatanJualRepository"

    override suspend fun listLots(): AppResult<List<MuatanJualListing>> =
        try {
            // v_lot_listings already filters to status='ACTIVE' and unexpired
            // (security-barrier view, 0006_carrier_commerce.sql) -- no
            // client-side filtering needed for correctness.
            val lots = SupabaseClientProvider.client.postgrest.from("v_lot_listings")
                .select(columns = Columns.raw(LOT_COLUMNS))
                .decodeList<LotListingDto>()
                .map { it.toDomain() }
            AppResult.Success(lots)
        } catch (t: Throwable) {
            SafeLog.e(tag, "lot listing call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toMuatanJualAppError())
        }
}

private fun Throwable.toMuatanJualAppError(): AppError = when {
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
