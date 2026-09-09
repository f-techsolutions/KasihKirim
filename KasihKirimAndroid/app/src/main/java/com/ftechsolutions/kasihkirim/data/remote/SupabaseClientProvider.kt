package com.ftechsolutions.kasihkirim.data.remote

import android.content.Context
import com.ftechsolutions.kasihkirim.BuildConfig
import com.ftechsolutions.kasihkirim.core.security.EncryptedSessionManager
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.auth.FlowType
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest

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
}
