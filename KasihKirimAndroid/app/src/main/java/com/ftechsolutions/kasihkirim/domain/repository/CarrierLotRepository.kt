package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierLot
import com.ftechsolutions.kasihkirim.domain.model.NewLot

/**
 * Muatan Jual (Phase 3) -- a carrier creating and managing their own stock
 * lots. Separate from [MuatanJualRepository] (the buyer-facing browse-only
 * repository, Phase 8): that one deliberately exposes no write path; this
 * one is entirely writes plus the carrier's own read.
 *
 * ref.compliance_state.status stays NOT_READY -- a legal/business decision,
 * unchanged by this repository's existence. Every RPC here still refuses
 * outright while the gate is off (rpc_create_lot's own
 * internal.fn_marketplace_gate call, 0047); this screen exists so a carrier
 * can prepare listings ahead of go-live, the same posture PromotionsScreen
 * already takes for kongsi_untung_enabled.
 */
interface CarrierLotRepository {
    /** The caller's own lots, any status -- lots_select's own RLS scopes an
     *  unfiltered read to the caller's carrier_id plus other carriers'
     *  ACTIVE rows; [carrierId] filters those out client-side. */
    suspend fun listMyLots(carrierId: String): AppResult<List<CarrierLot>>

    /** rpc_create_lot (0047). R-1's two caps (history + RM200 value ceiling)
     *  and the float-limit exposure check are enforced server-side; a
     *  refusal surfaces as a named AppError, never silently. */
    suspend fun createLot(draft: NewLot): AppResult<String>

    /** rpc_attach_lot_to_trip (0047) -- FR-442. Only a DRAFT lot on one of
     *  the caller's own BOARDING/ANNOUNCED/DRAFT trips can be attached. */
    suspend fun attachLotToTrip(lotId: String, tripId: String): AppResult<Unit>

    /** rpc_withdraw_lot (0047). Does not relieve the carrier's own
     *  inventory_at_risk_sen -- they still hold whatever was not sold. */
    suspend fun withdrawLot(lotId: String): AppResult<Unit>

    /** Uploads to the lot-photos bucket (public, buyer-visible) at
     *  {userId}/{uuid}.{ext} -- same path convention as product-images. */
    suspend fun uploadLotPhoto(photoBytes: ByteArray): AppResult<String>

    /** Uploads to the lot-receipts bucket (private -- FR-447, never a
     *  buyer's business) at {userId}/{uuid}.{ext}. */
    suspend fun uploadLotReceipt(photoBytes: ByteArray): AppResult<String>
}
