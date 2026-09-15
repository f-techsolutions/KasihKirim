package com.ftechsolutions.kasihkirim.domain.model

/** Mirrors ref.lot_status exactly (0006_carrier_commerce.sql). */
enum class LotStatus(val wire: String) {
    DRAFT("DRAFT"),
    ACTIVE("ACTIVE"),
    SOLD_OUT("SOLD_OUT"),
    EXPIRED("EXPIRED"),
    WITHDRAWN("WITHDRAWN"),
    WRITTEN_OFF("WRITTEN_OFF");

    val labelMs: String
        get() = when (this) {
            DRAFT -> "Draf"
            ACTIVE -> "Aktif"
            SOLD_OUT -> "Habis Dijual"
            EXPIRED -> "Tamat Tempoh"
            WITHDRAWN -> "Ditarik Balik"
            WRITTEN_OFF -> "Dihapus Kira"
        }

    companion object {
        fun fromWire(value: String): LotStatus? = entries.firstOrNull { it.wire == value }
    }
}

/** A carrier's own view of their public.carrier_stock_lots row -- unlike
 *  [MuatanJualListing] (the buyer-facing v_lot_listings projection), this
 *  carries costBasisSen: FR-447 keeps that private to the carrier and admin,
 *  never a buyer, but the carrier who owns the lot is exactly who this
 *  screen is for. */
data class CarrierLot(
    val id: String,
    val title: String,
    val status: LotStatus,
    val handlingFlags: List<HandlingFlag>,
    val unit: String,
    val qtyTotal: Double,
    val qtyReserved: Double,
    val qtySold: Double,
    val costBasisSen: Sen,
    val pricePerUnitSen: Sen,
    val tripId: String?,
    val sellBy: String?,
    val createdAt: String,
)

/** A lot the carrier is composing -- rpc_create_lot's params, 1:1. */
data class NewLot(
    val title: String,
    val categorySlug: String,
    val qtyTotal: Double,
    val costBasisSen: Long,
    val costReceiptPath: String,
    val pricePerUnitSen: Long,
    val unit: String = "kg",
    val handlingFlags: List<HandlingFlag> = emptyList(),
    val photoPaths: List<String> = emptyList(),
    val sellBy: String? = null,
)
