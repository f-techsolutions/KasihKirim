package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CapacityInvite
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

    /** Ajak Kirim (0006_carrier_commerce.sql) invites visible to the caller
     *  (invites_select's RLS: own community, direct target, or sender). */
    suspend fun listMyInvites(): AppResult<List<CapacityInvite>>

    /** Records that the caller acted on an invite -- a direct Postgrest
     *  insert into invite_responses (invite_resp_own's RLS, 0006), not an
     *  RPC. kirim_id is left null: linking the specific Kirim this response
     *  led to would need the invite to flow through the whole Kirim
     *  creation form's state, which is a larger follow-up than this tap. */
    suspend fun respondToInvite(inviteId: String): AppResult<Unit>
}
