package com.ftechsolutions.kasihkirim.ui.auth

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Email
import androidx.compose.material.icons.filled.Lock
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.painterResource
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
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(
                        MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.5f),
                        MaterialTheme.colorScheme.background,
                    ),
                ),
            )
            .verticalScroll(rememberScrollState())
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Surface(
            shape = MaterialTheme.shapes.large,
            color = MaterialTheme.colorScheme.surface,
            shadowElevation = 4.dp,
            modifier = Modifier.size(104.dp),
        ) {
            Image(
                painter = painterResource(R.drawable.logo_kasihkirim),
                contentDescription = stringResource(R.string.app_name),
                modifier = Modifier.padding(10.dp).clip(MaterialTheme.shapes.medium),
            )
        }
        Spacer(Modifier.height(16.dp))
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

            if (!isSignUp) {
                TextButton(
                    onClick = vm::sendPasswordReset,
                    enabled = form.canSendReset,
                    modifier = Modifier.align(Alignment.End),
                ) {
                    if (form.isSendingReset) {
                        CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.auth_forgot_password), style = MaterialTheme.typography.labelMedium)
                    }
                }
            }

            if (form.resetEmailSent) {
                Text(
                    text = stringResource(R.string.auth_reset_email_sent),
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }

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
    AppError.EmailNotConfirmed -> R.string.err_email_not_confirmed
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
        "PHOTO_PATH_REQUIRED" -> R.string.err_photo_path_required
        "PROOF_REQUIRED" -> R.string.err_proof_required
        "SELLER_APPLICATION_EXISTS" -> R.string.err_seller_application_exists
        "COMMUNITY_NOT_FOUND" -> R.string.err_community_not_found
        "BUSINESS_NAME_TOO_SHORT" -> R.string.err_business_name_too_short
        "PRODUCT_NOT_FOUND" -> R.string.err_product_not_found
        "PRODUCT_IMAGE_LIMIT" -> R.string.err_product_image_limit
        "CART_EMPTY" -> R.string.err_cart_empty
        "PRODUCT_NOT_AVAILABLE" -> R.string.err_product_not_available
        "INSUFFICIENT_STOCK" -> R.string.err_insufficient_stock
        "VOUCHER_REQUIRES_SINGLE_SELLER" -> R.string.err_voucher_requires_single_seller
        "VOUCHER_NOT_FOUND" -> R.string.err_voucher_not_found
        "VOUCHER_ALREADY_USED" -> R.string.err_voucher_already_used
        "VOUCHER_EXPIRED" -> R.string.err_voucher_expired
        "VOUCHER_MIN_ORDER" -> R.string.err_voucher_min_order
        "VOUCHER_LIMIT_REACHED" -> R.string.err_voucher_limit_reached
        "CAMPAIGN_NOT_ACTIVE" -> R.string.err_campaign_not_active
        "CAMPAIGN_BUDGET_EXHAUSTED" -> R.string.err_campaign_budget_exhausted
        "ORDER_NOT_FOUND" -> R.string.err_order_not_found
        "PAYMENT_METHOD_NOT_ENABLED" -> R.string.err_payment_method_not_enabled
        "PAYMENT_METHOD_UNKNOWN" -> R.string.err_payment_method_unknown
        "PAYMENT_METHOD_IS_COD" -> R.string.err_payment_method_is_cod
        "PAYMENT_NOT_PENDING" -> R.string.err_payment_not_pending
        "PAYMENT_MISSING" -> R.string.err_payment_missing
        "BILLPLZ_CREATE_BILL_FAILED" -> R.string.err_billplz_create_bill_failed
        "INVALID_CATEGORY" -> R.string.err_invalid_category
        "DESCRIPTION_TOO_SHORT" -> R.string.err_description_too_short
        "DISPUTE_ALREADY_OPEN" -> R.string.err_dispute_already_open
        "STATE_ACTOR_NOT_PERMITTED" -> R.string.err_state_actor_not_permitted
        "INVENTORY_NOT_FOUND" -> R.string.err_inventory_not_found
        "STOCK_NEGATIVE" -> R.string.err_stock_negative
        "STOCK_BELOW_RESERVED" -> R.string.err_stock_below_reserved
        "STOCK_DELTA_ZERO" -> R.string.err_stock_delta_zero
        "BUDGET_EXCEEDED_NEEDS_VARIANCE" -> R.string.err_budget_exceeded_needs_variance
        "INVALID_AMOUNT" -> R.string.err_invalid_amount
        else -> R.string.err_unexpected
    }
    else -> R.string.err_unexpected
}
