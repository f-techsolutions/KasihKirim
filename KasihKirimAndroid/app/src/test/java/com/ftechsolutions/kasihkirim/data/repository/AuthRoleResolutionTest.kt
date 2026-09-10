package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.data.remote.JwtClaims
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/**
 * Regression suite for the P0 JWT role/carrier_id bug fixed this session.
 * Exercises the actual production path -- [JwtClaims.appMetadata] (JWT
 * decode) feeding [buildAuthUser] (claim -> AuthUser mapping) -- the same
 * two functions `AuthRepositoryImpl.toAuthUser` and
 * `SupabaseClientProvider.currentJwtAppMetadata` delegate to in production.
 * Not a hardcoded ViewModel state, not a stand-in.
 *
 * The bug: the app used to read `UserInfo.appMetadata`, which mirrors
 * auth.users.raw_app_meta_data -- a column public.custom_access_token_hook
 * never writes to. The hook's role/carrier_id/seller_id/account_status
 * enrichment exists ONLY inside the minted JWT's own claims. A carrier or
 * seller account resolved to CUSTOMER, silently, with no error -- the exact
 * failure mode the last test in this file (case H) exists to catch.
 */
class AuthRoleResolutionTest {

    private fun b64url(s: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray())

    private fun fakeJwt(payloadJson: String): String {
        val header = b64url("""{"alg":"HS256","typ":"JWT"}""")
        return "$header.${b64url(payloadJson)}.fake-signature-not-verified-client-side"
    }

    private fun resolve(accessToken: String?, id: String = "u1", email: String? = "u@example.com") =
        buildAuthUser(id, email, JwtClaims.appMetadata(accessToken))

    // A. CUSTOMER token -> role resolves to CUSTOMER
    @Test fun `customer token resolves to CUSTOMER`() {
        val token = fakeJwt("""{"app_metadata":{"roles":["customer"]}}""")
        assertEquals(UserRole.CUSTOMER, resolve(token).primaryRole)
    }

    // B. CARRIER token -> role resolves to CARRIER
    @Test fun `carrier token resolves to CARRIER`() {
        val token = fakeJwt("""{"app_metadata":{"roles":["carrier"]}}""")
        assertEquals(UserRole.CARRIER, resolve(token).primaryRole)
    }

    // C. SELLER token -> role resolves to SELLER
    @Test fun `seller token resolves to SELLER`() {
        val token = fakeJwt("""{"app_metadata":{"roles":["seller"]}}""")
        assertEquals(UserRole.SELLER, resolve(token).primaryRole)
    }

    // D. CARRIER token with carrier_id -> carrier_id is correctly extracted
    @Test fun `carrier token carries carrier_id through to AuthUser`() {
        val token = fakeJwt(
            """{"app_metadata":{"roles":["carrier"],"carrier_id":"01a085d5-1d33-7e00-ae92-925faacc9129"}}""",
        )
        val user = resolve(token)
        assertEquals(UserRole.CARRIER, user.primaryRole)
        assertEquals("01a085d5-1d33-7e00-ae92-925faacc9129", user.carrierId)
    }

    @Test fun `seller token carries seller_id through, carrier_id stays null`() {
        val token = fakeJwt("""{"app_metadata":{"roles":["seller"],"seller_id":"s1"}}""")
        val user = resolve(token)
        assertEquals("s1", user.sellerId)
        assertNull(user.carrierId)
    }

    // E. token missing role -> safe deterministic fallback/error behavior
    @Test fun `app_metadata present but no roles key falls back to CUSTOMER, not a crash`() {
        val token = fakeJwt("""{"app_metadata":{"carrier_id":"c1"}}""")
        val user = resolve(token)
        assertEquals(UserRole.CUSTOMER, user.primaryRole)
        assertTrue(user.roles.isEmpty())
    }

    @Test fun `no app_metadata claim at all falls back to CUSTOMER, not a crash`() {
        assertEquals(UserRole.CUSTOMER, resolve(fakeJwt("""{"sub":"u1"}""")).primaryRole)
    }

    @Test fun `null access token falls back to CUSTOMER, not a crash`() {
        assertEquals(UserRole.CUSTOMER, resolve(null).primaryRole)
    }

    // F. token with unknown role -> safe deterministic behavior
    @Test fun `unknown role string is dropped, not guessed, falls back to CUSTOMER`() {
        val token = fakeJwt("""{"app_metadata":{"roles":["some_future_role_this_build_does_not_know"]}}""")
        val user = resolve(token)
        assertTrue(user.roles.isEmpty())
        assertEquals(UserRole.CUSTOMER, user.primaryRole)
    }

    @Test fun `a known role alongside an unknown one still resolves correctly`() {
        val token = fakeJwt("""{"app_metadata":{"roles":["mystery_role","carrier"]}}""")
        assertEquals(UserRole.CARRIER, resolve(token).primaryRole)
    }

    // G. malformed/invalid token -> no crash / safe failure
    @Test fun `garbage token string falls back to CUSTOMER, does not throw`() {
        assertEquals(UserRole.CUSTOMER, resolve("this-is-not-a-jwt").primaryRole)
    }

    @Test fun `token with corrupted base64 payload falls back to CUSTOMER, does not throw`() {
        assertEquals(UserRole.CUSTOMER, resolve("header.%%%not-base64%%%.sig").primaryRole)
    }

    // H. role resolution must use the decoded access-token claims, never a
    // stale/cached SDK user object -- the actual regression this session
    // fixed. buildAuthUser's signature only accepts an already-decoded
    // JsonObject; there is no code path here that could silently substitute
    // UserInfo.appMetadata instead, which is exactly what the original bug
    // did. Carrier and seller roles are only reachable at all by decoding
    // the token, exercised end-to-end below.
    @Test fun `role resolution goes through the decoded JWT -- carrier and seller are reachable, and precedence holds`() {
        val carrierToken = fakeJwt("""{"app_metadata":{"roles":["carrier"],"carrier_id":"c1"}}""")
        val sellerToken = fakeJwt("""{"app_metadata":{"roles":["seller"],"seller_id":"s1"}}""")
        assertEquals(UserRole.CARRIER, resolve(carrierToken).primaryRole)
        assertEquals(UserRole.SELLER, resolve(sellerToken).primaryRole)

        // AuthUser.primaryRole's own documented precedence: CARRIER wins if
        // both roles are present on one account.
        val both = fakeJwt("""{"app_metadata":{"roles":["seller","carrier"]}}""")
        assertEquals(UserRole.CARRIER, resolve(both).primaryRole)
    }
}
