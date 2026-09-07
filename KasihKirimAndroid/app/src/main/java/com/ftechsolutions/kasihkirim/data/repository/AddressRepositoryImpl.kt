package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.AddressDto
import com.ftechsolutions.kasihkirim.data.remote.dto.CommunityDto
import com.ftechsolutions.kasihkirim.data.remote.dto.NewAddressDto
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import io.github.jan.supabase.postgrest.query.Columns
import io.github.jan.supabase.postgrest.query.Order
import java.io.IOException

private const val ADDRESS_COLUMNS =
    "id,label,recipient_name,recipient_phone,landmark_note,is_default," +
        "community:communities(id,name,type,district,state)"

class AddressRepositoryImpl : AddressRepository {

    private val tag = "AddressRepository"

    override suspend fun listAddresses(): AppResult<List<Address>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("addresses")
            .select(columns = Columns.raw(ADDRESS_COLUMNS)) {
                order("is_default", Order.DESCENDING)
            }
            .decodeList<AddressDto>()
            .map { it.toDomain() }
    }

    override suspend fun createAddress(draft: NewAddress): AppResult<Address> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: return AppResult.Failure(AppError.SessionExpired)
        SupabaseClientProvider.client.postgrest.from("addresses")
            .insert(
                NewAddressDto(
                    userId = userId,
                    label = draft.label,
                    recipientName = draft.recipientName,
                    recipientPhone = draft.recipientPhone,
                    communityId = draft.communityId,
                    landmarkNote = draft.landmarkNote,
                ),
            ) { select(columns = Columns.raw(ADDRESS_COLUMNS)) }
            .decodeSingle<AddressDto>()
            .toDomain()
    }

    override suspend fun searchCommunities(query: String): AppResult<List<Community>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("communities")
            .select {
                filter {
                    eq("is_active", true)
                    if (query.isNotBlank()) ilike("name", "%$query%")
                }
                order("name", Order.ASCENDING)
                limit(30)
            }
            .decodeList<CommunityDto>()
            .map { it.toDomain() }
    }

    /** No stack trace, no raw payload to the caller -- mirrors
     *  AuthRepositoryImpl.toAppError() so both repositories fail the same way. */
    private inline fun <T> runCatchingResult(block: () -> T): AppResult<T> =
        try {
            AppResult.Success(block())
        } catch (t: Throwable) {
            SafeLog.e(tag, "address call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toAddressAppError())
        }
}

private fun Throwable.toAddressAppError(): AppError = when {
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
