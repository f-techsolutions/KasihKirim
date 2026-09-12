package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.auth.providers.builtin.Email
import io.github.jan.supabase.auth.user.UserInfo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.IOException

class AuthRepositoryImpl : AuthRepository {

    private val tag = "AuthRepository"
    private val _authState = MutableStateFlow<AuthState>(AuthState.Initializing)
    override val authState: StateFlow<AuthState> = _authState.asStateFlow()

    override suspend fun restoreSession() {
        if (!SupabaseClientProvider.isConfigured) {
            _authState.value = AuthState.Error(AppError.NotConfigured); return
        }
        _authState.value = AuthState.Initializing
        _authState.value = try {
            SupabaseClientProvider.client.auth.awaitInitialization()
            val user = SupabaseClientProvider.client.auth.currentUserOrNull()
            if (user != null) AuthState.Authenticated(user.toAuthUser()) else AuthState.Unauthenticated
        } catch (t: Throwable) {
            SafeLog.e(tag, "session restore failed", t)
            AuthState.Error(t.toAppError())
        }
    }

    override suspend fun signUpWithEmail(email: String, password: String): AppResult<AuthUser> =
        runAuth(noSessionError = AppError.EmailNotConfirmed) {
            SupabaseClientProvider.client.auth.signUpWith(Email) {
                this.email = email; this.password = password
            }
            // Depending on project settings sign-up may not create a session
            // (email confirmation). Treat "no session" as unauthenticated
            // rather than pretending the user is signed in. Found on-device:
            // this is the ordinary, successful outcome of a real sign-up on
            // a project with email confirmation enabled -- signUpWith()
            // returns without throwing, the account genuinely exists, there
            // is just no session yet. runAuth's default (SessionExpired,
            // which AuthScreen.messageRes() has no specific copy for and
            // falls back to a generic "Ada masalah. Sila cuba lagi.") made a
            // successful sign-up look like a random failure. EmailNotConfirmed
            // already has the exactly right string: "check your inbox for the
            // confirmation link."
            SupabaseClientProvider.client.auth.currentUserOrNull()
        }

    override suspend fun signInWithEmail(email: String, password: String): AppResult<AuthUser> =
        runAuth {
            SupabaseClientProvider.client.auth.signInWith(Email) {
                this.email = email; this.password = password
            }
            SupabaseClientProvider.client.auth.currentUserOrNull()
        }

    override suspend fun signOut(): AppResult<Unit> {
        return try {
            SupabaseClientProvider.client.auth.signOut()
            _authState.value = AuthState.Unauthenticated
            AppResult.Success(Unit)
        } catch (t: Throwable) {
            SafeLog.e(tag, "sign out failed", t)
            // Local state is cleared regardless: leaving the user apparently
            // signed in after they tapped sign out is worse than a failed
            // server round trip.
            _authState.value = AuthState.Unauthenticated
            AppResult.Failure(t.toAppError())
        }
    }

    private inline fun runAuth(
        noSessionError: AppError = AppError.SessionExpired,
        block: () -> UserInfo?,
    ): AppResult<AuthUser> =
        try {
            val info = block()
            if (info == null) {
                _authState.value = AuthState.Unauthenticated
                AppResult.Failure(noSessionError)
            } else {
                val user = info.toAuthUser()
                _authState.value = AuthState.Authenticated(user)
                AppResult.Success(user)
            }
        } catch (t: Throwable) {
            // Never log the credentials or the raw body.
            SafeLog.e(tag, "auth call failed: ${t::class.simpleName}", t)
            // Deliberately does NOT touch _authState. A wrong password (or any
            // other sign-in/sign-up failure) is a routine, expected outcome of
            // an attempt made while already Unauthenticated -- returning the
            // Failure below is enough for AuthViewModel to surface it as a
            // local form.error the user can read and correct. Setting
            // AuthState.Error here (found on-device: App.kt's root `when`
            // renders AuthState.Error as a bare, buttonless error screen with
            // no sign-in form at all) used to strand the user with no way to
            // retry short of restarting the app. AuthState.Error stays
            // reserved for restoreSession()'s own catch, where there really
            // is no form to fall back to.
            AppResult.Failure(t.toAppError())
        }
}

/**
 * Roles come from the JWT app_metadata claim written by
 * public.custom_access_token_hook -- never from a client-side table read, and
 * never from user input (§4). Deliberately reads the decoded access token
 * (SupabaseClientProvider.currentJwtAppMetadata()), not this UserInfo's own
 * appMetadata field: that field mirrors auth.users.raw_app_meta_data, which
 * the hook never writes to -- its enrichment only ever lands in the JWT.
 */
internal fun UserInfo.toAuthUser(): AuthUser =
    buildAuthUser(id, email, SupabaseClientProvider.currentJwtAppMetadata())

/**
 * The actual claim -> AuthUser mapping, split out from [toAuthUser] so it's
 * unit-testable against a hand-built app_metadata JsonObject without needing
 * to construct a real UserInfo or touch SupabaseClientProvider's singleton --
 * see AuthRoleResolutionTest, which exists specifically to protect this
 * mapping from regressing to reading the wrong metadata source again.
 */
internal fun buildAuthUser(id: String, email: String?, appMetadata: JsonObject?): AuthUser {
    val roles = (appMetadata?.get("roles") as? JsonArray)
        ?.mapNotNull { (it as? JsonPrimitive)?.content }
        .orEmpty()
    fun str(key: String) = (appMetadata?.get(key) as? JsonPrimitive)?.content?.takeIf { it != "null" }
    return AuthUser(
        id = id,
        email = email,
        roles = UserRole.parseAll(roles),
        carrierId = str("carrier_id"),
        sellerId = str("seller_id"),
        accountStatus = str("account_status"),
    )
}

internal fun Throwable.toAppError(): AppError = when {
    this is IOException -> AppError.Network
    // GoTrue's own literal message for a login attempt on an unconfirmed
    // account -- checked before the broader "credentials" match below so it
    // isn't swallowed into a generic wrong-password error.
    message?.contains("Email not confirmed", true) == true -> AppError.EmailNotConfirmed
    message?.contains("Invalid login", true) == true -> AppError.InvalidCredentials
    message?.contains("credentials", true) == true -> AppError.InvalidCredentials
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    else -> AppError.Unexpected
}
