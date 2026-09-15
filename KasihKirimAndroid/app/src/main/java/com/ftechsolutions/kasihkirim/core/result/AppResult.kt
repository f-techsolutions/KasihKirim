package com.ftechsolutions.kasihkirim.core.result

/**
 * Every repository call returns this. Errors are a closed set of domain
 * failures, not raw exceptions: §17 requires human-readable messages and
 * forbids leaking stack traces to users.
 */
sealed interface AppResult<out T> {
    data class Success<T>(val data: T) : AppResult<T>
    data class Failure(val error: AppError) : AppResult<Nothing>
}

sealed interface AppError {
    data object InvalidCredentials : AppError
    /** GoTrue's own "Email not confirmed" -- distinct from InvalidCredentials
     *  so the UI can point the user at their inbox instead of the password
     *  field. */
    data object EmailNotConfirmed : AppError
    /** Authenticated, but the backend refused: RLS or a policy said no. */
    data object NotAuthorized : AppError
    data object SessionExpired : AppError
    data object Network : AppError
    data object Timeout : AppError
    data class Validation(val field: String, val reason: String) : AppError
    data class Server(val code: String?) : AppError
    /** SUPABASE_URL / key absent from local.properties. */
    data object NotConfigured : AppError
    data object Unexpected : AppError
}

inline fun <T, R> AppResult<T>.map(transform: (T) -> R): AppResult<R> = when (this) {
    is AppResult.Success -> AppResult.Success(transform(data))
    is AppResult.Failure -> this
}
