package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.Serviceability

/**
 * public.addresses is RLS-scoped to "own" for select/insert/update, soft
 * delete only (DATABASE.md §14 RLS matrix): deleteAddress sets deleted_at,
 * it never issues a SQL DELETE.
 */
interface AddressRepository {
    /** Excludes soft-deleted rows. */
    suspend fun listAddresses(): AppResult<List<Address>>
    suspend fun createAddress(draft: NewAddress): AppResult<Address>
    suspend fun updateAddress(id: String, draft: NewAddress): AppResult<Address>

    /** Clears is_default on the user's other addresses first, then sets it
     *  on this one -- ux_addresses_one_default only allows one row with
     *  is_default true per user, so the clear must land before the set. */
    suspend fun setDefaultAddress(id: String): AppResult<Unit>

    /** Soft delete: sets deleted_at, matching the "soft only" RLS policy. */
    suspend fun deleteAddress(id: String): AppResult<Unit>

    /** ref/public geography, read-only. Empty query returns active
     *  communities in Sabah, most recently added first is NOT guaranteed --
     *  callers should not assume an order beyond what's documented. */
    suspend fun searchCommunities(query: String): AppResult<List<Community>>

    /** Asks the SERVER whether a lane is served -- never decided in Kotlin.
     *  originNodeId/destNodeId are ref.route_nodes(id), reached here only via
     *  Community.nodeId (ref itself is not PostgREST-exposed). */
    suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability>
}
