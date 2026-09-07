package com.ftechsolutions.kasihkirim.domain

import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.TransportMode
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import org.junit.Assert.*
import org.junit.Test

/**
 * These assert the CLIENT matches the BACKEND enums. If a migration adds a
 * value and this file is not updated, the test fails -- which is the intent.
 * Source: ref.kirim_status / ref.vehicle_type / ref.user_role in
 * supabase/migrations/0000_prelude.sql.
 */
class BackendEnumContractTest {

    @Test fun `kirim_status has all 20 backend values`() {
        assertEquals(20, KirimStatus.entries.size)
    }

    /** The brief's example state machine contained ACCEPTED. The backend does
     *  not. POSTED goes to MATCHED. */
    @Test fun `there is no ACCEPTED status`() {
        assertNull(KirimStatus.fromWire("ACCEPTED"))
        assertNotNull(KirimStatus.fromWire("MATCHED"))
    }

    /** BELI procures before pickup, so PROCURING must exist. */
    @Test fun `PROCURING exists for the BELI flow`() {
        assertNotNull(KirimStatus.fromWire("PROCURING"))
    }

    @Test fun `terminal states match ARCHITECTURE section 5_1`() {
        assertTrue(KirimStatus.COMPLETED.isTerminal)
        assertTrue(KirimStatus.CANCELLED.isTerminal)
        assertTrue(KirimStatus.REFUNDED.isTerminal)
        assertFalse(KirimStatus.IN_TRANSIT.isTerminal)
        assertFalse(KirimStatus.FAILED_PICKUP.isTerminal)   // has RETRY/CANCEL
    }

    /** BOAT is a peer of CAR, not a Paitan exception. */
    @Test fun `vehicle_type includes BOAT as a first-class mode`() {
        assertEquals(7, TransportMode.entries.size)
        assertNotNull(TransportMode.fromWire("BOAT"))
        assertNotNull(TransportMode.fromWire("CAR"))
    }

    @Test fun `unknown wire values are dropped not guessed`() {
        assertNull(UserRole.fromWire("superuser"))
        assertEquals(setOf(UserRole.CARRIER), UserRole.parseAll(listOf("carrier", "wizard")))
    }

    @Test fun `admin roles are identified by prefix`() {
        assertTrue(UserRole.ADMIN_FINANCE.isAdmin)
        assertFalse(UserRole.CARRIER.isAdmin)
    }
}
