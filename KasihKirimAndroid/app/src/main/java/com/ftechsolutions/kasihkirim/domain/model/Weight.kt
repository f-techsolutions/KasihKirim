package com.ftechsolutions.kasihkirim.domain.model

import java.util.Locale

/**
 * Presentation only, mirroring [Sen.format]'s role for money. Weight is
 * always grams (Int) end to end -- this never becomes an authoritative type,
 * it just formats.
 *
 * Found on-device: `"${grams / 1000}kg"` at every call site truncated any
 * weight under 1000g to "0kg" (integer division), which is the common case
 * for small rural goods (dried fish, spices, produce sold by the hundred
 * grams). Below 1kg this shows grams directly; at or above, kg with at most
 * one decimal place and no trailing ".0".
 */
fun Int.formatGrams(): String =
    if (this < 1000) {
        "${this}g"
    } else {
        "${kgDecimalString()}kg"
    }

/** The bare numeric kg string, no unit -- for a reserved/capacity ratio like
 *  "0.5/10kg" where both sides must share one unit and one trailing "kg",
 *  not [formatGrams]'s own per-value g/kg switch (which would otherwise
 *  read as the equally-wrong "500g/10kg"). */
fun Int.kgDecimalString(): String {
    // Locale.US pins the decimal separator to "." regardless of device
    // locale -- a comma-locale device would otherwise silently turn this
    // into "2,5kg", trading one display bug for another.
    val rounded = String.format(Locale.US, "%.1f", this / 1000.0)
    return if (rounded.endsWith(".0")) rounded.dropLast(2) else rounded
}
