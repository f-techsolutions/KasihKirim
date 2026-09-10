package com.ftechsolutions.kasihkirim.data.remote

import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Base64

/**
 * Regression coverage for the P0 bug fixed this session: the app used to
 * read role/carrier_id off `UserInfo.appMetadata`, which mirrors
 * auth.users.raw_app_meta_data -- a column public.custom_access_token_hook
 * never writes to -- instead of decoding the actual JWT the hook enriches.
 * This exercises the real production decoder, [JwtClaims.appMetadata], not
 * a stand-in, against hand-built fake tokens: no real credentials, no
 * network, no Android Context, no Supabase service.
 */
class JwtClaimsTest {

    private fun b64url(s: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray())

    private fun fakeJwt(payloadJson: String): String {
        val header = b64url("""{"alg":"HS256","typ":"JWT"}""")
        return "$header.${b64url(payloadJson)}.fake-signature-not-verified-client-side"
    }

    @Test fun `decodes app_metadata from a well-formed access token`() {
        val token = fakeJwt(
            """{"sub":"u1","app_metadata":{"roles":["carrier"],"carrier_id":"c1","seller_id":null,"account_status":"active"}}""",
        )
        val meta = JwtClaims.appMetadata(token)
        assertNotNull(meta)
        assertEquals(listOf("carrier"), meta!!["roles"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals("c1", meta["carrier_id"]!!.jsonPrimitive.content)
    }

    @Test fun `null access token returns null, not a crash`() {
        assertNull(JwtClaims.appMetadata(null))
    }

    @Test fun `token with no dot segments returns null, not a crash`() {
        assertNull(JwtClaims.appMetadata("not-a-jwt-at-all"))
    }

    @Test fun `token with invalid base64 payload returns null, not a crash`() {
        assertNull(JwtClaims.appMetadata("header.!!!not-valid-base64!!!.sig"))
    }

    @Test fun `token whose payload is valid base64 but not JSON returns null, not a crash`() {
        val notJson = b64url("this is not json")
        assertNull(JwtClaims.appMetadata("header.$notJson.sig"))
    }

    @Test fun `token with no app_metadata claim returns null`() {
        assertNull(JwtClaims.appMetadata(fakeJwt("""{"sub":"u1"}""")))
    }

    @Test fun `unpadded base64url payload (the real JWT shape) still decodes`() {
        // fakeJwt() always encodes without padding, same as a real Supabase
        // access token -- this documents that the manual re-padding inside
        // appMetadata() is exercised, not dead code.
        val token = fakeJwt("""{"app_metadata":{"roles":["seller"]}}""")
        assertNotNull(JwtClaims.appMetadata(token))
    }
}
