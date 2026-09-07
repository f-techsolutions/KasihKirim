package com.ftechsolutions.kasihkirim.domain.model

import java.math.BigDecimal
import java.math.RoundingMode

/**
 * Money is BIGINT sen in the backend (50 such columns in migration 0001).
 *
 * §31 forbids Double/Float as an authoritative representation. This wraps a
 * Long and deliberately offers NO multiply, NO percentage and NO commission
 * helper: those belong to internal.fn_* on the server. The client displays
 * what rpc_quote_kirim and rpc_my_earnings return.
 */
@JvmInline
value class Sen(val value: Long) : Comparable<Sen> {

    /** Presentation only. Never feed the result back into a calculation. */
    fun format(): String =
        "RM " + BigDecimal(value).divide(BigDecimal(100), 2, RoundingMode.UNNECESSARY).toPlainString()

    operator fun plus(other: Sen) = Sen(value + other.value)
    override fun compareTo(other: Sen) = value.compareTo(other.value)

    companion object {
        val ZERO = Sen(0)
        fun of(raw: Long) = Sen(raw)
    }
}
