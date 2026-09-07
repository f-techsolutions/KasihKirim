package com.ftechsolutions.kasihkirim.data.remote

import com.ftechsolutions.kasihkirim.BuildConfig
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

    val isConfigured: Boolean
        get() = BuildConfig.SUPABASE_URL.isNotBlank() &&
                BuildConfig.SUPABASE_PUBLISHABLE_KEY.isNotBlank()

    val client: SupabaseClient by lazy {
        check(isConfigured) {
            "SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY missing. " +
                "Copy local.properties.example to local.properties."
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
            }
            install(Postgrest)
        }
    }
}
