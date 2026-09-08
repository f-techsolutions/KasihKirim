package com.ftechsolutions.kasihkirim.domain.model

/**
 * rpc_my_earnings's response (0005_rpc_surface.sql). cod_held_sen and
 * float_limit_sen are only present when the caller resolves to a carrier --
 * the RPC returns just available/pending (both zero) for anyone else.
 */
data class Earnings(
    val availableSen: Sen,
    val pendingSen: Sen,
    val codHeldSen: Sen?,
    val floatLimitSen: Sen?,
)
