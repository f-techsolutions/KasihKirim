package com.ftechsolutions.kasihkirim.ui.auth

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.ui.common.AppCard

@Composable
fun AuthScreen(vm: AuthViewModel) {
    val form by vm.form.collectAsStateWithLifecycle()
    var isSignUp by rememberSaveable { mutableStateOf(false) }

    Column(
        modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            stringResource(R.string.app_name),
            style = MaterialTheme.typography.headlineLarge.copy(fontWeight = FontWeight.Bold),
            color = MaterialTheme.colorScheme.primary,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stringResource(R.string.tagline),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(28.dp))

        AppCard {
            OutlinedTextField(
                value = form.email,
                onValueChange = vm::onEmailChange,
                label = { Text(stringResource(R.string.auth_email)) },
                leadingIcon = { Icon(Icons.Filled.Email, contentDescription = null) },
                singleLine = true,
                isError = form.email.isNotEmpty() && !form.emailValid,
                supportingText = {
                    if (form.email.isNotEmpty() && !form.emailValid)
                        Text(stringResource(R.string.err_invalid_email))
                },
                shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))

            OutlinedTextField(
                value = form.password,
                onValueChange = vm::onPasswordChange,
                label = { Text(stringResource(R.string.auth_password)) },
                leadingIcon = { Icon(Icons.Filled.Lock, contentDescription = null) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                isError = form.password.isNotEmpty() && !form.passwordValid,
                supportingText = {
                    if (form.password.isNotEmpty() && !form.passwordValid)
                        Text(stringResource(R.string.err_password_short))
                },
                shape = MaterialTheme.shapes.small,
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

            Spacer(Modifier.height(20.dp))
            Button(
                onClick = { if (isSignUp) vm.signUp() else vm.signIn() },
                enabled = form.canSubmit,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
            ) {
                if (form.isSubmitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                } else {
                    Text(
                        stringResource(if (isSignUp) R.string.auth_sign_up else R.string.auth_sign_in),
                        style = MaterialTheme.typography.labelLarge,
                    )
                }
            }

            Spacer(Modifier.height(4.dp))
            TextButton(
                onClick = { isSignUp = if (isSignUp) false else true; vm.clearError() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(if (isSignUp) R.string.auth_have_account else R.string.auth_no_account))
            }
        }

        // Phone sign-in is intentionally absent, not disabled-looking: there is
        // no SMS provider configured in supabase/config.toml, so offering it
        // would promise something the backend cannot do.
        Spacer(Modifier.height(16.dp))
        Text(
            stringResource(R.string.auth_phone_soon),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Maps a domain error to a human-readable string. Raw exceptions never
 *  reach the user (§17). */
internal fun AppError.messageRes(): Int = when (this) {
    AppError.InvalidCredentials -> R.string.err_credentials
    AppError.Network, AppError.Timeout -> R.string.err_network
    AppError.NotConfigured -> R.string.err_not_configured
    is AppError.Server -> when (code) {
        "BUDGET_CAP_EXCEEDED" -> R.string.err_budget_cap_exceeded
        "CATEGORY_NOT_FOUND" -> R.string.err_category_not_found
        "VEHICLE_NOT_FOUND" -> R.string.err_vehicle_not_found
        "INVALID_CORRIDOR" -> R.string.err_invalid_corridor
        "DEPART_TIME_IN_PAST" -> R.string.err_depart_time_in_past
        "QUOTE_NOT_FOUND" -> R.string.err_quote_not_found
        "QUOTE_ALREADY_CONSUMED" -> R.string.err_quote_consumed
        "QUOTE_EXPIRED" -> R.string.err_quote_expired
        "ADDRESS_NOT_FOUND" -> R.string.err_address_not_found
        "ORIGIN_ADDRESS_REQUIRED" -> R.string.err_origin_address_required
        "BELI_REQUIRES_BUDGET" -> R.string.err_beli_requires_budget
        "STATE_INVALID_TRANSITION" -> R.string.err_state_invalid_transition
        "SELF_DEALING" -> R.string.err_self_dealing
        "FLOAT_LIMIT_EXCEEDED" -> R.string.err_float_limit_exceeded
        "CAPACITY_EXCEEDED" -> R.string.err_capacity_exceeded
        "TRIP_NOT_FOUND" -> R.string.err_trip_not_found
        "TRIP_NOT_BOARDING" -> R.string.err_trip_not_boarding
        "DELIVERY_NOT_FOUND" -> R.string.err_delivery_not_found
        else -> R.string.err_unexpected
    }
    else -> R.string.err_unexpected
}
