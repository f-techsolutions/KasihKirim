package com.ftechsolutions.kasihkirim.domain

import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.domain.model.appliesTo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Regression for a real bug: delivery action buttons were gated on account-
 * wide role membership alone (`UserRole.CARRIER in roles`), so a dual-role
 * account (a customer who is also a carrier) saw carrier-only buttons on a
 * delivery it placed as a customer but someone else is carrying -- the
 * server would reject the tap with STATE_ACTOR_NOT_PERMITTED, but the
 * button was shown regardless. [appliesTo] mirrors rpc_delivery_transition's
 * own per-delivery substantiation (0030) so the button is never offered.
 */
class DeliveryTransitionRuleTest {

    private val delivery = Delivery(
        id = "d1", status = KirimStatus.MATCHED, kirimType = KirimType.HANTAR,
        referenceCode = "KK-2609-000001", itemDescription = "Ikan kering",
        codAmountSen = Sen(5000), carrierEarningSen = Sen(1350), failureReason = null,
        matchedAt = "2026-09-08T00:00:00Z",
        carrierId = "carrier-1", requesterId = "customer-1",
    )

    @Test fun `carrier role applies only when this account's carrierId matches the delivery's`() {
        assertTrue(UserRole.CARRIER.appliesTo(delivery, "someone-else", "carrier-1", setOf(UserRole.CARRIER)))
        assertFalse(UserRole.CARRIER.appliesTo(delivery, "someone-else", "carrier-2", setOf(UserRole.CARRIER)))
        assertFalse(UserRole.CARRIER.appliesTo(delivery, "someone-else", null, setOf(UserRole.CARRIER)))
    }

    @Test fun `a dual-role account does not get carrier buttons on its own customer delivery`() {
        // customer-1 placed this delivery and also happens to hold a carrier
        // account (carrier-9), but carrier-1 -- not carrier-9 -- is carrying it.
        assertFalse(UserRole.CARRIER.appliesTo(delivery, "customer-1", "carrier-9", setOf(UserRole.CUSTOMER, UserRole.CARRIER)))
        assertTrue(UserRole.CUSTOMER.appliesTo(delivery, "customer-1", "carrier-9", setOf(UserRole.CUSTOMER, UserRole.CARRIER)))
    }

    @Test fun `customer role applies only when this account's id matches the delivery's requester`() {
        assertTrue(UserRole.CUSTOMER.appliesTo(delivery, "customer-1", null, setOf(UserRole.CUSTOMER)))
        assertFalse(UserRole.CUSTOMER.appliesTo(delivery, "someone-else", null, setOf(UserRole.CUSTOMER)))
    }

    @Test fun `holding the role account-wide is still required, substantiation alone is not enough`() {
        // Matches by id, but the account doesn't actually hold the role.
        assertFalse(UserRole.CARRIER.appliesTo(delivery, "x", "carrier-1", emptySet()))
        assertFalse(UserRole.CUSTOMER.appliesTo(delivery, "customer-1", null, emptySet()))
    }

    @Test fun `agent and admin roles stay account-wide, not tied to a single delivery's parties`() {
        assertTrue(UserRole.AGENT.appliesTo(delivery, "anyone", null, setOf(UserRole.AGENT)))
        assertFalse(UserRole.AGENT.appliesTo(delivery, "anyone", null, emptySet()))
    }
}
