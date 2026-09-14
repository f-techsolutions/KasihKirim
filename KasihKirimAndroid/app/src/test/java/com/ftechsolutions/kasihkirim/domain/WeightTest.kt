package com.ftechsolutions.kasihkirim.domain

import com.ftechsolutions.kasihkirim.domain.model.formatGrams
import com.ftechsolutions.kasihkirim.domain.model.kgDecimalString
import org.junit.Assert.assertEquals
import org.junit.Test

/** Regression for the "0kg" bug found on-device: `"${grams / 1000}kg"`
 *  truncated any weight under 1000g to zero via integer division. */
class WeightTest {

    @Test fun `weight under 1kg shows grams, not a truncated 0kg`() {
        assertEquals("500g", 500.formatGrams())
        assertEquals("1g", 1.formatGrams())
        assertEquals("999g", 999.formatGrams())
    }

    @Test fun `weight at or above 1kg shows kg, dropping a trailing zero decimal`() {
        assertEquals("1kg", 1000.formatGrams())
        assertEquals("2kg", 2000.formatGrams())
        assertEquals("2.5kg", 2500.formatGrams())
        assertEquals("50kg", 50000.formatGrams())
    }

    @Test fun `zero grams is a real zero, not the same bug in a different spot`() {
        assertEquals("0g", 0.formatGrams())
    }

    @Test fun `kgDecimalString gives the bare number for a reserved-capacity ratio`() {
        // The Trips screen's "0.5/10kg" -- both sides must share one unit and
        // one trailing "kg", so this returns the number alone.
        assertEquals("0.5", 500.kgDecimalString())
        assertEquals("10", 10000.kgDecimalString())
        assertEquals("0", 0.kgDecimalString())
    }
}
