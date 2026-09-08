package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.KirimCreated
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.KirimSubmission
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary

interface KirimRepository {
    suspend fun quoteKirim(draft: KirimDraft): AppResult<KirimQuote>

    /** Consumes a quote from quoteKirim and posts the Kirim (rpc_create_kirim,
     *  0012_kirim_trip_creation.sql). A quote can only be consumed once. */
    suspend fun createKirim(submission: KirimSubmission): AppResult<KirimCreated>

    /** POSTED items visible on the board -- kirim_select's RLS policy scopes
     *  this to carriers (plus the requester's own rows, which the caller
     *  should prefer listMyKirims for). */
    suspend fun listBoard(): AppResult<List<KirimSummary>>

    /** The caller's own Kirim requests, every status, own rows only. */
    suspend fun listMyKirims(): AppResult<List<KirimSummary>>
}
