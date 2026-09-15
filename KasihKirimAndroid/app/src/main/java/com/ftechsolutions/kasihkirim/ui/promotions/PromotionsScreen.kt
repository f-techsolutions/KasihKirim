@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.promotions

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.BankAccount
import com.ftechsolutions.kasihkirim.domain.model.MyPromotion
import com.ftechsolutions.kasihkirim.domain.model.OpenedPromotion
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest
import com.ftechsolutions.kasihkirim.domain.model.PayoutStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.GradientHeroCard
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

/** Kongsi & Untung: redeem a shared code (rpc_open_promotion), see the
 *  promoter's own codes and earnings (rpc_my_promotions), and cash out
 *  through the same bank-account/withdrawal flow a carrier or seller
 *  already uses. Every action here surfaces KONGSI_UNTUNG_DISABLED
 *  cleanly (like any other server error) rather than hiding the screen
 *  entirely -- see PromotionRepository's own header comment. */
@Composable
fun PromotionsScreen(vm: PromotionsViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.promo_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when {
                state.isLoading && state.promotions.isEmpty() && state.error == null ->
                    Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    item { Spacer(Modifier.height(4.dp)) }

                    item {
                        RedeemCodeCard(
                            code = state.redeemCode,
                            onCodeChange = vm::onRedeemCodeChange,
                            isRedeeming = state.isRedeeming,
                            result = state.redeemResult,
                            onRedeem = vm::redeemCode,
                        )
                    }

                    item {
                        GradientHeroCard {
                            Column {
                                Text(
                                    stringResource(R.string.promo_available),
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.82f),
                                )
                                Spacer(Modifier.height(6.dp))
                                Text(
                                    state.availableSen.format(),
                                    style = MaterialTheme.typography.headlineLarge,
                                    color = MaterialTheme.colorScheme.onPrimary,
                                )
                            }
                        }
                    }

                    item {
                        PromoWithdrawSection(
                            availableSen = state.availableSen,
                            bankAccounts = state.bankAccounts,
                            isSubmitting = state.isSubmitting,
                            onAddBankAccount = vm::addBankAccount,
                            onWithdraw = vm::requestWithdrawal,
                        )
                    }

                    item { Text(stringResource(R.string.promo_my_codes_title), style = MaterialTheme.typography.titleMedium) }
                    if (state.promotions.isEmpty()) {
                        item { EmptyStateCard(stringResource(R.string.promo_no_codes), stringResource(R.string.promo_no_codes_hint)) }
                    }
                    state.promotions.forEach { promo -> item { PromotionCard(promo) } }

                    if (state.payouts.isNotEmpty()) {
                        item { Text(stringResource(R.string.earnings_payout_history_title), style = MaterialTheme.typography.titleMedium) }
                        state.payouts.forEach { payout -> item { PromoPayoutCard(payout) } }
                    }

                    state.error?.let {
                        item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }
                    }
                    item { Spacer(Modifier.height(24.dp)) }
                }
            }
        }
    }
}

@Composable
private fun RedeemCodeCard(
    code: String,
    onCodeChange: (String) -> Unit,
    isRedeeming: Boolean,
    result: OpenedPromotion?,
    onRedeem: () -> Unit,
) {
    AppCard {
        Text(stringResource(R.string.promo_redeem_title), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(
                value = code,
                onValueChange = onCodeChange,
                label = { Text(stringResource(R.string.promo_redeem_code_label)) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.weight(1f),
            )
            Button(
                onClick = onRedeem,
                enabled = !isRedeeming && code.isNotBlank(),
                shape = MaterialTheme.shapes.medium,
            ) {
                if (isRedeeming) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.promo_redeem_submit))
                }
            }
        }
        if (result != null) {
            Spacer(Modifier.height(10.dp))
            if (result.found) {
                Text(
                    result.title ?: result.sellerName ?: "-",
                    style = MaterialTheme.typography.bodyMedium,
                )
                result.priceSen?.let {
                    Text(it.format(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                Text(
                    stringResource(R.string.promo_redeem_not_found),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

@Composable
private fun PromotionCard(promo: MyPromotion) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(promo.subjectLabel ?: promo.code, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(2.dp))
                Text(
                    promo.code,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            StatusBadge(
                stringResource(R.string.promo_click_count, promo.clickCount),
                tone = BadgeTone.INFO,
            )
        }
        Spacer(Modifier.height(10.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Column {
                Text(
                    stringResource(R.string.promo_pending),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(promo.pendingSen.format(), style = MaterialTheme.typography.bodyMedium)
            }
            Column {
                Text(
                    stringResource(R.string.promo_settled),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(promo.settledSen.format(), style = MaterialTheme.typography.bodyMedium)
            }
        }
    }
}

/** Mirrors EarningsScreen's own WithdrawSection, kept as its own smaller
 *  copy rather than a shared composable -- that one is private to its file
 *  and threads a PayeeType choice this screen never needs (always PROMOTER). */
@Composable
private fun PromoWithdrawSection(
    availableSen: Sen,
    bankAccounts: List<BankAccount>,
    isSubmitting: Boolean,
    onAddBankAccount: (String, String, String) -> Unit,
    onWithdraw: (String, Long) -> Unit,
) {
    var addingAccount by remember { mutableStateOf(false) }
    var withdrawing by remember { mutableStateOf(false) }

    AppCard {
        Text(stringResource(R.string.earnings_bank_accounts_title), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))

        if (bankAccounts.isEmpty()) {
            Text(
                stringResource(R.string.earnings_no_bank_account),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        } else {
            bankAccounts.forEach { account ->
                Text(
                    "${account.bankCode} •••• ${account.accountNoLast4} (${account.holderName})",
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        }

        Spacer(Modifier.height(10.dp))
        if (addingAccount) {
            var bankCode by remember { mutableStateOf("") }
            var accountNo by remember { mutableStateOf("") }
            var holderName by remember { mutableStateOf("") }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = bankCode, onValueChange = { bankCode = it },
                    label = { Text(stringResource(R.string.earnings_bank_code_label)) },
                    singleLine = true, shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = accountNo, onValueChange = { accountNo = it },
                    label = { Text(stringResource(R.string.earnings_account_no_label)) },
                    singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = holderName, onValueChange = { holderName = it },
                    label = { Text(stringResource(R.string.earnings_holder_name_label)) },
                    singleLine = true, shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = {
                            onAddBankAccount(bankCode.trim(), accountNo.trim(), holderName.trim())
                            addingAccount = false
                        },
                        enabled = !isSubmitting && bankCode.isNotBlank() && accountNo.isNotBlank() && holderName.isNotBlank(),
                        shape = MaterialTheme.shapes.medium,
                    ) { Text(stringResource(R.string.earnings_add_bank_submit)) }
                    TextButton(onClick = { addingAccount = false }) { Text(stringResource(R.string.earnings_cancel)) }
                }
            }
        } else {
            TextButton(onClick = { addingAccount = true }, enabled = !isSubmitting) {
                Text(stringResource(R.string.earnings_add_bank_account))
            }
        }

        Spacer(Modifier.height(6.dp))
        HorizontalDivider()
        Spacer(Modifier.height(10.dp))

        if (withdrawing && bankAccounts.isNotEmpty()) {
            var selectedBankAccountId by remember { mutableStateOf(bankAccounts.first().id) }
            var amountRinggit by remember { mutableStateOf("") }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (bankAccounts.size > 1) {
                    bankAccounts.forEach { account ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(
                                selected = selectedBankAccountId == account.id,
                                onClick = { selectedBankAccountId = account.id },
                            )
                            Text("${account.bankCode} •••• ${account.accountNoLast4}")
                        }
                    }
                }
                OutlinedTextField(
                    value = amountRinggit,
                    onValueChange = { amountRinggit = it },
                    label = { Text(stringResource(R.string.earnings_withdraw_amount_label)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    shape = MaterialTheme.shapes.small,
                    modifier = Modifier.fillMaxWidth(),
                )
                val amountSen = (amountRinggit.toDoubleOrNull()?.takeIf { it > 0 } ?: 0.0).let { (it * 100).toLong() }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = {
                            onWithdraw(selectedBankAccountId, amountSen)
                            withdrawing = false
                        },
                        enabled = !isSubmitting && amountSen > 0,
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        if (isSubmitting) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.earnings_withdraw_submit))
                        }
                    }
                    TextButton(onClick = { withdrawing = false }, enabled = !isSubmitting) {
                        Text(stringResource(R.string.earnings_cancel))
                    }
                }
            }
        } else {
            if (availableSen > Sen.ZERO) {
                Button(
                    onClick = { withdrawing = true },
                    enabled = !isSubmitting && bankAccounts.isNotEmpty(),
                    shape = MaterialTheme.shapes.medium,
                ) { Text(stringResource(R.string.earnings_withdraw)) }
            }
            if (bankAccounts.isEmpty()) {
                Spacer(Modifier.height(6.dp))
                Text(
                    stringResource(R.string.earnings_withdraw_needs_bank_account),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun PromoPayoutCard(payout: PayoutRequest) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                payout.amountSen.format(),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            StatusBadge(
                payout.status.labelMs,
                tone = when (payout.status) {
                    PayoutStatus.PAID -> BadgeTone.POSITIVE
                    PayoutStatus.REJECTED, PayoutStatus.FAILED -> BadgeTone.ERROR
                    else -> BadgeTone.WARNING
                },
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(
            "${payout.bankCode} •••• ${payout.accountNoLast4}",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
