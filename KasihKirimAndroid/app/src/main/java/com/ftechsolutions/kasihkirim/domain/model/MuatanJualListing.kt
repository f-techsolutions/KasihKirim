package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors ref.handling_flag exactly (0001_schema.sql) -- a plain enum column
 * on carrier_stock_lots, not a foreign key, so (unlike category_id) its wire
 * values are stable and safe to mirror directly, the same shape as
 * KirimStatus/TripStatus.
 */
enum class HandlingFlag(val wire: String) {
    FRAGILE("FRAGILE"),
    PERISHABLE("PERISHABLE"),
    COLD_CHAIN("COLD_CHAIN"),
    LIQUID("LIQUID"),
    OVERSIZED("OVERSIZED"),
    LIVE_ANIMAL("LIVE_ANIMAL"),
    DOCUMENTS("DOCUMENTS"),
    HALAL_SEPARATE("HALAL_SEPARATE");

    val labelMs: String
        get() = when (this) {
            FRAGILE -> "Mudah Pecah"
            PERISHABLE -> "Mudah Rosak"
            COLD_CHAIN -> "Rantaian Sejuk"
            LIQUID -> "Cecair"
            OVERSIZED -> "Saiz Besar"
            LIVE_ANIMAL -> "Haiwan Hidup"
            DOCUMENTS -> "Dokumen"
            HALAL_SEPARATE -> "Berasingan Halal"
        }

    companion object {
        fun fromWire(value: String): HandlingFlag? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * A row of public.v_lot_listings -- the security-barrier view over
 * carrier_stock_lots that already filters to status='ACTIVE' and unexpired,
 * and deliberately omits cost_basis_sen/cost_receipt_path (the carrier's
 * margin, never shown to a buyer).
 *
 * category_id is NOT carried here: it is a UUID into ref.categories, which
 * is not PostgREST-exposed (supabase/config.toml) and whose id is a random
 * uuidv7() with no pinned literal in seed.sql -- there is currently no safe
 * way for this client to resolve it to a name, and the view does not join
 * one in. Showing the raw UUID would be worse than not showing a category.
 *
 * Browse-only by design (Phase 8): rpc_buy_from_lot exists but does not
 * enforce ref.compliance_state or ref.feature_gates before moving money
 * (both live in the ref schema, also unreachable from this client to check
 * live), and a "successful" call never persists an order -- only a stock
 * reservation. No purchase action is offered here until the backend closes
 * that gap.
 */
data class MuatanJualListing(
    val id: String,
    val carrierId: String,
    val title: String,
    val handlingFlags: List<HandlingFlag>,
    val unit: String,
    val pricePerUnitSen: Sen,
    val qtyAvailable: Double,
    val sellBy: String?,
)
