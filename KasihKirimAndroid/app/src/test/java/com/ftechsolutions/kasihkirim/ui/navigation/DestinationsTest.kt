package com.ftechsolutions.kasihkirim.ui.navigation

import com.ftechsolutions.kasihkirim.data.remote.JwtClaims
import com.ftechsolutions.kasihkirim.data.repository.buildAuthUser
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import java.util.Base64

/**
 * Navigation-contract regression test: a CARRIER or SELLER role must never
 * silently present the CUSTOMER tab set because role decoding failed
 * upstream -- the P0 bug this session's JWT fix addresses. AuthRoleResolutionTest
 * covers the decode itself; this covers the downstream consequence a broken
 * decode was actually visible as (the carrier/seller demo accounts showing
 * "Customer" and the customer tab bar).
 */
class DestinationsTest {

    @Test fun `customer tabs are Utama Kirim Papan Pesanan Profil`() {
        assertEquals(
            listOf(Destination.HOME, Destination.SEND, Destination.BOARD, Destination.ORDERS, Destination.PROFILE),
            tabsFor(UserRole.CUSTOMER),
        )
    }

    @Test fun `carrier tabs are Utama Papan Trip Pesanan Duit Profil`() {
        assertEquals(
            listOf(
                Destination.HOME, Destination.BOARD, Destination.TRIPS,
                Destination.ORDERS, Destination.EARNINGS, Destination.PROFILE,
            ),
            tabsFor(UserRole.CARRIER),
        )
    }

    @Test fun `seller tabs are Utama Muatan Jual Pesanan Jualan Profil`() {
        assertEquals(
            listOf(Destination.HOME, Destination.MUATAN_JUAL, Destination.ORDERS, Destination.SALES, Destination.PROFILE),
            tabsFor(UserRole.SELLER),
        )
    }

    @Test fun `carrier tabs never silently collapse to customer tabs`() {
        assertNotEquals(tabsFor(UserRole.CUSTOMER), tabsFor(UserRole.CARRIER))
    }

    @Test fun `seller tabs never silently collapse to customer tabs`() {
        assertNotEquals(tabsFor(UserRole.CUSTOMER), tabsFor(UserRole.SELLER))
    }

    @Test fun `roles with no dedicated tab set fall back to customer tabs deterministically, not a crash`() {
        // AGENT and admin roles aren't customer-facing in this app; tabsFor's
        // `else` branch is the same deterministic fallback as
        // AuthUser.primaryRole's own CUSTOMER default -- not a crash, not an
        // empty tab bar.
        assertEquals(tabsFor(UserRole.CUSTOMER), tabsFor(UserRole.AGENT))
        assertEquals(tabsFor(UserRole.CUSTOMER), tabsFor(UserRole.ADMIN_SUPER))
    }

    // End-to-end: a real carrier JWT, decoded the production way, must drive
    // the carrier tab set -- not the customer one. This is the exact
    // regression: before this session's fix, this test would have failed
    // with tabsFor(user.primaryRole) == the CUSTOMER list, because
    // user.primaryRole would always have been CUSTOMER.
    @Test fun `a real carrier JWT drives carrier tabs end-to-end, never customer tabs`() {
        val header = Base64.getUrlEncoder().withoutPadding().encodeToString("""{"alg":"HS256","typ":"JWT"}""".toByteArray())
        val payload = Base64.getUrlEncoder().withoutPadding()
            .encodeToString("""{"app_metadata":{"roles":["carrier"],"carrier_id":"c1"}}""".toByteArray())
        val token = "$header.$payload.fake-signature-not-verified-client-side"

        val user = buildAuthUser("u1", "u@example.com", JwtClaims.appMetadata(token))

        assertEquals(UserRole.CARRIER, user.primaryRole)
        assertEquals(tabsFor(UserRole.CARRIER), tabsFor(user.primaryRole))
        assertNotEquals(tabsFor(UserRole.CUSTOMER), tabsFor(user.primaryRole))
    }
}
