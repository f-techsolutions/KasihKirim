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

    /** rpc_record_purchase (0037). The only write path for a BELI delivery's
     *  actual_goods_sen -- also advances PROCURING -> AWAITING_PICKUP.
     *  Carrier-only, BELI-only, PROCURING-only; the server rejects anything
     *  else with a named error, never a silent no-op. */
    suspend fun recordPurchase(deliveryId: String, actualGoodsSen: Long): AppResult<KirimStatus>

    /** rpc_open_carrier_dispute (0039) -- a carrier-facing counterpart to
     *  rpc_open_dispute/rpc_open_seller_dispute (customer/seller), authorized
     *  the same way rpc_delivery_transition (0030) already authorizes a
     *  carrier's own delivery: d.carrier_id must match the caller's own
     *  carrier id, not role membership alone. Applies to every kirim_type,
     *  unlike the seller path which is PASARAN-only. */
    suspend fun openDispute(deliveryId: String, category: String, description: String): AppResult<Unit>

    /** Ids of deliveries the caller has already reviewed (rpc_submit_review,
     *  0044) -- visible or not, since an invisible review still counts as
     *  "already rated" for the purpose of showing/hiding the Rate button. */
    suspend fun listMyReviewedDeliveryIds(): AppResult<Set<String>>

    /** rpc_submit_review (0044). The only write path onto public.reviews --
     *  the server derives who the other party is from the delivery itself
     *  and refuses anyone who wasn't actually part of it. Also the edit
     *  path: calling this again for the same delivery within
     *  reviews.editable_until (24h) replaces the caller's own prior rating. */
    suspend fun submitReview(deliveryId: String, rating: Int, comment: String?): AppResult<Unit>
}
