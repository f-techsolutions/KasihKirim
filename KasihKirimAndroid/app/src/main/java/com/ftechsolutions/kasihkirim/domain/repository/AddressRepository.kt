package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.NewAddress

/**
 * public.addresses is RLS-scoped to "own" for select/insert/update, soft
 * delete only (DATABASE.md §14 RLS matrix). There is no delete() here on
 * purpose: this repository does not expose one.
 */
interface AddressRepository {
    suspend fun listAddresses(): AppResult<List<Address>>
    suspend fun createAddress(draft: NewAddress): AppResult<Address>

    /** ref/public geography, read-only. Empty query returns active
     *  communities in Sabah, most recently added first is NOT guaranteed --
     *  callers should not assume an order beyond what's documented. */
    suspend fun searchCommunities(query: String): AppResult<List<Community>>
}
