package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.CarrierLot
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.LotStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for the carrier's own public.carrier_stock_lots read --
 *  lots_select's own RLS already scopes an unfiltered read to the caller's
 *  own carrier_id (plus any other carrier's ACTIVE rows, filtered out
 *  client-side by the repository's own carrier_id match). Unlike
 *  [LotListingDto] (the buyer-facing v_lot_listings projection) this reads
 *  cost_basis_sen directly -- FR-447 keeps it from buyers, not from the
 *  carrier who owns the lot. */
@Serializable
data class CarrierLotDto(
    val id: String,
    val title: String,
    val status: String,
    @SerialName("handling_flags") val handlingFlags: List<String> = emptyList(),
    val unit: String,
    @SerialName("qty_total") val qtyTotal: Double,
    @SerialName("qty_reserved") val qtyReserved: Double,
    @SerialName("qty_sold") val qtySold: Double,
    @SerialName("cost_basis_sen") val costBasisSen: Long,
    @SerialName("price_per_unit_sen") val pricePerUnitSen: Long,
    @SerialName("trip_id") val tripId: String? = null,
    @SerialName("sell_by") val sellBy: String? = null,
    @SerialName("created_at") val createdAt: String,
) {
    fun toDomain() = CarrierLot(
        id = id,
        title = title,
        status = LotStatus.fromWire(status) ?: LotStatus.DRAFT,
        handlingFlags = handlingFlags.mapNotNull(HandlingFlag::fromWire),
        unit = unit,
        qtyTotal = qtyTotal,
        qtyReserved = qtyReserved,
        qtySold = qtySold,
        costBasisSen = Sen(costBasisSen),
        pricePerUnitSen = Sen(pricePerUnitSen),
        tripId = tripId,
        sellBy = sellBy,
        createdAt = createdAt,
    )
}
