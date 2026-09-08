package com.ftechsolutions.kasihkirim.data.remote.dto

import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.domain.model.Sen
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/** Row shape for public.v_lot_listings (0006_carrier_commerce.sql), the
 *  columns this client reads to browse the Muatan Jual marketplace. */
@Serializable
data class LotListingDto(
    val id: String,
    @SerialName("carrier_id") val carrierId: String,
    val title: String,
    @SerialName("handling_flags") val handlingFlags: List<String> = emptyList(),
    val unit: String,
    @SerialName("price_per_unit_sen") val pricePerUnitSen: Long,
    @SerialName("qty_available") val qtyAvailable: Double,
    @SerialName("sell_by") val sellBy: String? = null,
) {
    fun toDomain() = MuatanJualListing(
        id = id,
        carrierId = carrierId,
        title = title,
        handlingFlags = handlingFlags.mapNotNull(HandlingFlag::fromWire),
        unit = unit,
        pricePerUnitSen = Sen(pricePerUnitSen),
        qtyAvailable = qtyAvailable,
        sellBy = sellBy,
    )
}
