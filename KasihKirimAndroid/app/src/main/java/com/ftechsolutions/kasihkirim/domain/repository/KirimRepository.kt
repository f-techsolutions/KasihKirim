package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote

/**
 * Quote only. rpc_create_kirim (actually submitting a Kirim request) does
 * not exist in the backend yet -- see docs/CLAUDE_IMPLEMENTATION_PLAN.md §3
 * gap list. This repository does not expose a submit/create method on
 * purpose: there is nothing for it to call.
 */
interface KirimRepository {
    suspend fun quoteKirim(draft: KirimDraft): AppResult<KirimQuote>
}
