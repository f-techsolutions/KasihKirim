package com.ftechsolutions.kasihkirim.ui.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class AuthFormState(
    val email: String = "",
    val password: String = "",
    val isSubmitting: Boolean = false,
    val error: AppError? = null,
    val isSendingReset: Boolean = false,
    val resetEmailSent: Boolean = false,
) {
    // Client-side validation is UX only. The server validates again, and the
    // server is the control (mirrors the Zod-schema comment in apps/mobile).
    val emailValid: Boolean get() = email.contains("@") && email.length >= 5
    val passwordValid: Boolean get() = password.length >= 8
    val canSubmit: Boolean get() = emailValid && passwordValid && !isSubmitting
    val canSendReset: Boolean get() = emailValid && !isSendingReset
}

class AuthViewModel(private val repo: AuthRepository) : ViewModel() {

    val authState: StateFlow<AuthState> = repo.authState

    private val _form = MutableStateFlow(AuthFormState())
    val form: StateFlow<AuthFormState> = _form.asStateFlow()

    init { viewModelScope.launch { repo.restoreSession() } }

    fun onEmailChange(v: String) {
        _form.value = _form.value.copy(email = v.trim(), error = null, resetEmailSent = false)
    }
    fun onPasswordChange(v: String) { _form.value = _form.value.copy(password = v, error = null) }
    fun clearError() { _form.value = _form.value.copy(error = null) }

    fun signIn() = submit { repo.signInWithEmail(_form.value.email, _form.value.password) }
    fun signUp() = submit { repo.signUpWithEmail(_form.value.email, _form.value.password) }

    /** Fire-and-forget: never touches isSubmitting/canSubmit, so it can run
     *  independently of (and without disturbing) a sign-in attempt. */
    fun sendPasswordReset() {
        if (!_form.value.canSendReset) return
        viewModelScope.launch {
            _form.value = _form.value.copy(isSendingReset = true, error = null, resetEmailSent = false)
            _form.value = when (val result = repo.sendPasswordReset(_form.value.email)) {
                is AppResult.Success -> _form.value.copy(isSendingReset = false, resetEmailSent = true)
                is AppResult.Failure -> _form.value.copy(isSendingReset = false, error = result.error)
            }
        }
    }

    fun signOut() = viewModelScope.launch {
        repo.signOut()
        _form.value = AuthFormState()   // never retain credentials across sessions
    }

    private fun submit(call: suspend () -> AppResult<*>) = viewModelScope.launch {
        if (!_form.value.canSubmit) return@launch
        _form.value = _form.value.copy(isSubmitting = true, error = null)
        val result = call()
        _form.value = when (result) {
            is AppResult.Success -> AuthFormState()          // clears the password
            is AppResult.Failure -> _form.value.copy(isSubmitting = false, error = result.error)
        }
    }

    /** Manual DI. Hilt is not introduced in Phase 1: one dependency does not
     *  justify an annotation processor (§9). */
    class Factory(private val repo: AuthRepository) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = AuthViewModel(repo) as T
    }
}
