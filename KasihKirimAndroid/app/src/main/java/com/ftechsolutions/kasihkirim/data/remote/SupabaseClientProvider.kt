package com.ftechsolutions.kasihkirim.data.remote

import android.content.Context
import com.ftechsolutions.kasihkirim.BuildConfig
import com.ftechsolutions.kasihkirim.core.security.EncryptedSessionManager
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

/**
 * ONE shared client for the whole app (§13). Creating one per screen would
 * fragment session state and multiply refresh traffic on a rural connection.
 *
 * Only the PUBLISHABLE key is used. It is public by design and useless without
 * a valid JWT, because RLS is the authorization boundary. A service_role key
 * in an APK would bypass RLS on every table -- §4, non-negotiable.
 */
object SupabaseClientProvider {

    /** Set once from [com.ftechsolutions.kasihkirim.KasihKirimApplication.onCreate]. */
    private lateinit var appContext: Context

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    val isConfigured: Boolean
        get() = BuildConfig.SUPABASE_URL.isNotBlank() &&
                BuildConfig.SUPABASE_PUBLISHABLE_KEY.isNotBlank()

    val client: SupabaseClient by lazy {
        check(isConfigured) {
            "SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY missing. " +
                "Copy local.properties.example to local.properties."
        }
        check(::appContext.isInitialized) {
            "SupabaseClientProvider.init(context) was never called."
        }
        createSupabaseClient(
            supabaseUrl = BuildConfig.SUPABASE_URL,
            supabaseKey = BuildConfig.SUPABASE_PUBLISHABLE_KEY,
        ) {
            install(Auth) {
                // PKCE: no client secret, and the code verifier never leaves
                // the device. Required for a public mobile client.
                flowType = FlowType.PKCE
                scheme = "kasihkirim"
                host = "auth"
                autoLoadFromStorage = true
                alwaysAutoRefresh = true
                // Without this, Auth falls back to its own default
                // SessionManager, which stores the session unencrypted --
                // see EncryptedSessionManager's doc comment.
                sessionManager = EncryptedSessionManager(appContext)
            }
            install(Postgrest)
        }
    }

    /**
     * app_metadata as enriched by public.custom_access_token_hook (roles,
     * carrier_id, seller_id, account_status).
     *
     * This is deliberately NOT `client.auth.currentUserOrNull()?.appMetadata`
     * -- that object mirrors auth.users.raw_app_meta_data, a column the hook
     * never writes to. The hook only enriches the claims of the JWT it mints;
     * that enrichment exists solely inside the access token itself, so
     * reading it back means decoding the current access token's payload, not
     * asking the SDK's cached user object.
     *
     * The decode itself is delegated to [JwtClaims.appMetadata], a pure
     * function with no SupabaseClient/Context dependency, so the regression
     * this fixed (silently falling back to the wrong, stale metadata source)
     * has a real unit test -- see JwtClaimsTest.
     */
    fun currentJwtAppMetadata(): JsonObject? =
        JwtClaims.appMetadata(client.auth.currentSessionOrNull()?.accessToken)
}

/** Split out of SupabaseClientProvider so the JWT-decoding logic itself is
 *  unit-testable without a live SupabaseClient (which needs an Android
 *  Context and network config to even construct). Behavior is unchanged from
 *  before the split -- see JwtClaimsTest for the regression coverage this
 *  exists to carry. */
internal object JwtClaims {
    fun appMetadata(accessToken: String?): JsonObject? {
        val token = accessToken ?: return null
        return try {
            val payload = token.split(".").getOrNull(1) ?: return null
            val padded = payload + "=".repeat((4 - payload.length % 4) % 4)
            val bytes = java.util.Base64.getUrlDecoder().decode(padded)
            Json.parseToJsonElement(bytes.decodeToString()).jsonObject["app_metadata"] as? JsonObject
        } catch (e: Exception) {
            null
        }
    }
}
