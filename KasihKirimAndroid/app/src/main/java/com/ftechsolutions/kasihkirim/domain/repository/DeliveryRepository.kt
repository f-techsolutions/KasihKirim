package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus

interface DeliveryRepository {
    /** The caller's own deliveries, as carrier and/or requester -- RLS
     *  decides which, this makes no role distinction itself. */
    suspend fun listMyDeliveries(): AppResult<List<Delivery>>

    /** rpc_delivery_transition (0003_functions_rls.sql). Returns the new
     *  status; the server is the sole authority on whether this event is
     *  legal from the delivery's current state. */
    suspend fun transition(deliveryId: String, event: String): AppResult<KirimStatus>

    /** Uploads [photoBytes] to the `pod` storage bucket, submits it via
     *  rpc_submit_proof for [leg], then advances the delivery via [event].
     *  The two RPC calls are not reorderable: internal.fn_delivery_transition
     *  refuses a requires_proof=true event with PROOF_REQUIRED unless a
     *  matching public.proofs row already exists for that leg. */
    suspend fun submitProofAndTransition(
        deliveryId: String,
        leg: String,
        event: String,
        photoBytes: ByteArray,
    ): AppResult<KirimStatus>
}
