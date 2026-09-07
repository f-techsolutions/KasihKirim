package com.ftechsolutions.kasihkirim.core.security

import android.util.Log
import com.ftechsolutions.kasihkirim.BuildConfig

/**
 * The only logging entry point in the app.
 *
 * §4 forbids logging passwords, OTPs, tokens, service keys and payment
 * secrets. Relying on every developer to remember that does not work, so
 * redaction happens here and debug output is dropped from release builds.
 */
object SafeLog {

    private val SENSITIVE = listOf(
        Regex("""eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"""),
        Regex("""sb_(publishable|secret)_[A-Za-z0-9_\-]+"""),
        Regex("""(?i)(password|passwd|otp|token|secret|api[_\-]?key)\s*[=:]\s*\S+"""),
        Regex("""\b\d{6}\b"""),
        Regex("""\+60\d{8,10}"""),
    )

    fun redact(message: String): String =
        SENSITIVE.fold(message) { acc, re -> re.replace(acc, "[REDACTED]") }

    fun d(tag: String, message: String) {
        if (BuildConfig.DEBUG) Log.d(tag, redact(message))
    }

    /** Errors are logged in release too, always redacted, and without the
     *  throwable in release -- exception messages routinely carry request
     *  bodies. */
    fun e(tag: String, message: String, t: Throwable? = null) {
        Log.e(tag, redact(message), if (BuildConfig.DEBUG) t else null)
    }
}
