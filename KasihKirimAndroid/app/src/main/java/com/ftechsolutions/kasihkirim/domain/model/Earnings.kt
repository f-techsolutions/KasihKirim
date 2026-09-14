package com.ftechsolutions.kasihkirim.domain.model

/**
 * rpc_my_earnings's response (0005_rpc_surface.sql / 0029). availableSen/
 * pendingSen/codHeldSen/floatLimitSen are the CARRIER side and are only
 * present when the caller resolves to a carrier. sellerAvailableSen/
 * sellerPendingSen are the seller side of the exact same RPC call --
 * a dual-role user gets both halves back in one response; a pure seller
 * gets zeroed carrier fields and null cod/float, same as a pure carrier
 * gets zeroed seller fields.
 *
 * There is no seller equivalent of codHeldSen: COD cash is physically held
 * by the carrier who collected it, never by the seller, so a "COD held for
 * seller" figure would have no backing number in the ledger -- see
 * rpc_my_earnings' own SQL, which computes cod_held_sen only from
 * public.carriers. Money a seller is owed from a COD sale that hasn't
 * settled yet already shows up in sellerPendingSen.
 */
data class Earnings(
    val availableSen: Sen,
    val pendingSen: Sen,
    val codHeldSen: Sen?,
    val floatLimitSen: Sen?,
    val sellerAvailableSen: Sen? = null,
    val sellerPendingSen: Sen? = null,
)
