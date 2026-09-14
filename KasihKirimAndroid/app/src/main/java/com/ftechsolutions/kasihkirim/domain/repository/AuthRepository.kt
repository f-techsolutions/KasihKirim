package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import kotlinx.coroutines.flow.StateFlow

/**
 * Phase 1 is email/password only.
 *
 * Phone OTP is deliberately absent rather than stubbed: supabase/config.toml
 * has an [auth.sms] template but NO provider block, so an OTP screen would
 * promise something the backend cannot deliver. The interface is shaped so
 * phone sign-in can be added later without rewriting callers.
 */
interface AuthRepository {
    val authState: StateFlow<AuthState>

    /** Restores a persisted session at startup. Safe to call repeatedly. */
    suspend fun restoreSession()

    suspend fun signUpWithEmail(email: String, password: String): AppResult<AuthUser>
    suspend fun signInWithEmail(email: String, password: String): AppResult<AuthUser>
    suspend fun signOut(): AppResult<Unit>

    /** Sends a password-recovery email. Never touches authState: this is a
     *  fire-and-forget request against an email address, not a session
     *  change -- whether it succeeds or fails, the caller's sign-in state is
     *  whatever it already was. */
    suspend fun sendPasswordReset(email: String): AppResult<Unit>
}
