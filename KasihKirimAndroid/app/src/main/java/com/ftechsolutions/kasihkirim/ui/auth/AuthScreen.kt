package com.ftechsolutions.kasihkirim.ui.auth

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.core.result.AppError

@Composable
fun AuthScreen(vm: AuthViewModel) {
    val form by vm.form.collectAsStateWithLifecycle()
    var isSignUp by rememberSaveable { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineLarge)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.tagline), style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(32.dp))

        OutlinedTextField(
            value = form.email,
            onValueChange = vm::onEmailChange,
            label = { Text(stringResource(R.string.auth_email)) },
            singleLine = true,
            isError = form.email.isNotEmpty() && !form.emailValid,
            supportingText = {
                if (form.email.isNotEmpty() && !form.emailValid)
                    Text(stringResource(R.string.err_invalid_email))
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(12.dp))

        OutlinedTextField(
            value = form.password,
            onValueChange = vm::onPasswordChange,
            label = { Text(stringResource(R.string.auth_password)) },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            isError = form.password.isNotEmpty() && !form.passwordValid,
            supportingText = {
                if (form.password.isNotEmpty() && !form.passwordValid)
                    Text(stringResource(R.string.err_password_short))
            },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            modifier = Modifier.fillMaxWidth(),
        )

        form.error?.let { err ->
            Spacer(Modifier.height(12.dp))
            Text(
                text = stringResource(err.messageRes()),
                color = MaterialTheme.colorScheme.error,
                style = MaterialTheme.typography.bodyMedium,
            )
        }

        Spacer(Modifier.height(24.dp))
        Button(
            onClick = { if (isSignUp) vm.signUp() else vm.signIn() },
            enabled = form.canSubmit,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) {
            if (form.isSubmitting) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(if (isSignUp) R.string.auth_sign_up else R.string.auth_sign_in))
            }
        }

        Spacer(Modifier.height(8.dp))
        TextButton(onClick = { isSignUp = if (isSignUp) false else true; vm.clearError() }) {
            Text(stringResource(if (isSignUp) R.string.auth_have_account else R.string.auth_no_account))
        }

        // Phone sign-in is intentionally absent, not disabled-looking: there is
        // no SMS provider configured in supabase/config.toml, so offering it
        // would promise something the backend cannot do.
        Spacer(Modifier.height(16.dp))
        Text(
            stringResource(R.string.auth_phone_soon),
            style = MaterialTheme.typography.labelSmall,
        )
    }
}

/** Maps a domain error to a human-readable string. Raw exceptions never
 *  reach the user (§17). */
internal fun AppError.messageRes(): Int = when (this) {
    AppError.InvalidCredentials -> R.string.err_credentials
    AppError.Network, AppError.Timeout -> R.string.err_network
    AppError.NotConfigured -> R.string.err_not_configured
    else -> R.string.err_unexpected
}
