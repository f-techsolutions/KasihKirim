package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.AddressDto
import com.ftechsolutions.kasihkirim.data.remote.dto.AddressUpdateDto
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
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.IOException
import java.time.Instant

private const val ADDRESS_COLUMNS =
    "id,label,recipient_name,recipient_phone,landmark_note,is_default," +
        "community:communities(id,name,type,district,state)"

@Serializable
private data class IsDefaultUpdate(@SerialName("is_default") val isDefault: Boolean)

@Serializable
private data class DeletedAtUpdate(@SerialName("deleted_at") val deletedAt: String)

class AddressRepositoryImpl : AddressRepository {

    private val tag = "AddressRepository"

    override suspend fun listAddresses(): AppResult<List<Address>> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("addresses")
            .select(columns = Columns.raw(ADDRESS_COLUMNS)) {
                filter { exact("deleted_at", null) }
                order("is_default", Order.DESCENDING)
            }
            .decodeList<AddressDto>()
            .map { it.toDomain() }
    }

    override suspend fun setDefaultAddress(id: String): AppResult<Unit> = runCatchingResult {
        val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
            ?: return AppResult.Failure(AppError.SessionExpired)
        val table = SupabaseClientProvider.client.postgrest.from("addresses")
        // Clear first: ux_addresses_one_default allows at most one row with
        // is_default true per user, so setting the new default before
        // clearing the old one would violate it.
        table.update(IsDefaultUpdate(false)) {
            filter {
                eq("user_id", userId)
                eq("is_default", true)
            }
        }
        table.update(IsDefaultUpdate(true)) {
            filter { eq("id", id) }
        }
        Unit
    }

    override suspend fun deleteAddress(id: String): AppResult<Unit> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("addresses")
            .update(DeletedAtUpdate(Instant.now().toString())) {
                filter { eq("id", id) }
            }
        Unit
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

    override suspend fun updateAddress(id: String, draft: NewAddress): AppResult<Address> = runCatchingResult {
        SupabaseClientProvider.client.postgrest.from("addresses")
            .update(
                AddressUpdateDto(
                    label = draft.label,
                    recipientName = draft.recipientName,
                    recipientPhone = draft.recipientPhone,
                    communityId = draft.communityId,
                    landmarkNote = draft.landmarkNote,
                ),
            ) {
                filter { eq("id", id) }
                select(columns = Columns.raw(ADDRESS_COLUMNS))
            }
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
