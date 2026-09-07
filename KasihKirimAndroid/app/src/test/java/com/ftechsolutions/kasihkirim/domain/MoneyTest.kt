package com.ftechsolutions.kasihkirim.domain

import com.ftechsolutions.kasihkirim.domain.model.Sen
import org.junit.Assert.assertEquals
import org.junit.Test

class MoneyTest {

    @Test fun `formats sen as ringgit with two decimals`() {
        assertEquals("RM 12.50", Sen(1250).format())
        assertEquals("RM 0.01", Sen(1).format())
        assertEquals("RM 0.00", Sen.ZERO.format())
    }

    /** The deck's worked example: RM50 order, 25% commission = RM12.50. The
     *  client only ever DISPLAYS these; the server computes them. */
    @Test fun `renders backend-supplied amounts without recomputing`() {
        assertEquals("RM 50.00", Sen(5000).format())
        assertEquals("RM 12.50", Sen(1250).format())
    }

    @Test fun `addition stays exact at scale where Double would drift`() {
        var total = Sen.ZERO
        repeat(1_000) { total += Sen(1) }          // 1000 x 1 sen
        assertEquals(1_000L, total.value)
        assertEquals("RM 10.00", total.format())
    }

    @Test fun `large values do not lose precision`() {
        assertEquals("RM 92233720368547758.07", Sen(Long.MAX_VALUE).format())
    }
}
