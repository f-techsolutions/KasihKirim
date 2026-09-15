@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.earnings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.PayeeType
import com.ftechsolutions.kasihkirim.domain.model.PayoutRequest
import com.ftechsolutions.kasihkirim.domain.model.PayoutStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.GradientHeroCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun EarningsScreen(vm: EarningsViewModel) {
    val state by vm.state.collectAsState()

    // The bottom NavigationBar keeps this destination's ViewModel alive
    // across tab switches (saveState/restoreState in AppNavHost), but the
    // composable itself is disposed and re-entered -- without this, a
    // carrier who completes a delivery and switches Trips -> Earnings sees
    // the pre-completion figures until the process is killed and relaunched,
    // since init{}'s one-shot load() never re-fires on its own.
    LaunchedEffect(Unit) { vm.load() }

    Column(modifier = Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 20.dp)) {
            Spacer(Modifier.height(12.dp))
            ScreenHeader(stringResource(R.string.earnings_title))
        }

        when {
            state.isLoading && state.earnings == null ->
                Box(Modifier.fillMaxWidth().padding(top = 40.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            state.error != null && state.earnings == null -> Text(
                stringResource(state.error!!.messageRes()),
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(horizontal = 20.dp),
            )
            state.earnings != null -> LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item { Spacer(Modifier.height(4.dp)) }
                item { EarningsContent(state.earnings!!) }

                item {
                    WithdrawSection(
                        earnings = state.earnings!!,
                        bankAccounts = state.bankAccounts,
                        isSubmitting = state.isSubmitting,
                        onAddBankAccount = vm::addBankAccount,
                        onWithdraw = vm::requestWithdrawal,
                    )
                }

                item { Text(stringResource(R.string.earnings_payout_history_title), style = MaterialTheme.typography.titleMedium) }
                if (state.payouts.isEmpty()) {
                    item { EmptyStateCard(stringResource(R.string.earnings_no_payouts)) }
                }
                items(state.payouts, key = { it.id }) { payout -> PayoutHistoryCard(payout) }

                state.error?.let {
                    item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }
}

@Composable
private fun EarningsContent(earnings: Earnings) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        GradientHeroCard {
            Column {
                Text(
                    stringResource(R.string.earnings_available),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.82f),
                )
                Spacer(Modifier.height(6.dp))
                Text(
                    earnings.availableSen.format(),
                    style = MaterialTheme.typography.headlineLarge,
                    color = MaterialTheme.colorScheme.onPrimary,
                )
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile(stringResource(R.string.earnings_pending), earnings.pendingSen.format(), Modifier.weight(1f))
            earnings.codHeldSen?.let {
                StatTile(stringResource(R.string.earnings_cod_held), it.format(), Modifier.weight(1f))
            }
        }
        earnings.floatLimitSen?.let {
            StatTile(stringResource(R.string.earnings_float_limit), it.format(), Modifier.fillMaxWidth())
        }

        earnings.sellerAvailableSen?.let { sellerAvailable ->
            Spacer(Modifier.height(4.dp))
            Text(stringResource(R.string.earnings_seller_section_title), style = MaterialTheme.typography.titleSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StatTile(stringResource(R.string.earnings_seller_available), sellerAvailable.format(), Modifier.weight(1f))
                earnings.sellerPendingSen?.let {
                    StatTile(stringResource(R.string.earnings_seller_pending), it.format(), Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun StatTile(label: String, value: String, modifier: Modifier = Modifier) {
    AppCard(modifier) {
        Text(
            label,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(6.dp))
        Text(value, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onSurface)
    }
}

/** One card that covers both bank accounts and withdrawing -- an empty
 *  bank account list is itself the reason a withdraw form can't be shown
 *  yet, so keeping them together avoids a second card that just says
 *  "add a bank account first" in isolation. */
@Composable
private fun WithdrawSection(
    earnings: Earnings,
    bankAccounts: List<BankAccount>,
    isSubmitting: Boolean,
    onAddBankAccount: (String, String, String) -> Unit,
    onWithdraw: (PayeeType, String, Long) -> Unit,
) {
    var addingAccount by remember { mutableStateOf(false) }
    var withdrawing by remember { mutableStateOf<PayeeType?>(null) }

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
            AddBankAccountForm(
                isSubmitting = isSubmitting,
                onSubmit = { bankCode, accountNo, holderName ->
                    onAddBankAccount(bankCode, accountNo, holderName)
                    addingAccount = false
                },
                onCancel = { addingAccount = false },
            )
        } else {
            TextButton(onClick = { addingAccount = true }, enabled = !isSubmitting) {
                Text(stringResource(R.string.earnings_add_bank_account))
            }
        }

        Spacer(Modifier.height(6.dp))
        HorizontalDivider()
        Spacer(Modifier.height(10.dp))

        val action = withdrawing
        if (action != null) {
            WithdrawForm(
                bankAccounts = bankAccounts,
                isSubmitting = isSubmitting,
                onSubmit = { bankAccountId, amountSen ->
                    onWithdraw(action, bankAccountId, amountSen)
                    withdrawing = null
                },
                onCancel = { withdrawing = null },
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (earnings.availableSen > Sen.ZERO) {
                    Button(
                        onClick = { withdrawing = PayeeType.CARRIER },
                        enabled = !isSubmitting && bankAccounts.isNotEmpty(),
                        shape = MaterialTheme.shapes.medium,
                    ) { Text(stringResource(R.string.earnings_withdraw)) }
                }
                earnings.sellerAvailableSen?.takeIf { it > Sen.ZERO }?.let {
                    OutlinedButton(
                        onClick = { withdrawing = PayeeType.SELLER },
                        enabled = !isSubmitting && bankAccounts.isNotEmpty(),
                        shape = MaterialTheme.shapes.medium,
                    ) { Text(stringResource(R.string.earnings_seller_section_title) + ": " + stringResource(R.string.earnings_withdraw)) }
                }
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
private fun AddBankAccountForm(
    isSubmitting: Boolean,
    onSubmit: (String, String, String) -> Unit,
    onCancel: () -> Unit,
) {
    var bankCode by remember { mutableStateOf("") }
    var accountNo by remember { mutableStateOf("") }
    var holderName by remember { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = bankCode,
            onValueChange = { bankCode = it },
            label = { Text(stringResource(R.string.earnings_bank_code_label)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = accountNo,
            onValueChange = { accountNo = it },
            label = { Text(stringResource(R.string.earnings_account_no_label)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = holderName,
            onValueChange = { holderName = it },
            label = { Text(stringResource(R.string.earnings_holder_name_label)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = { onSubmit(bankCode.trim(), accountNo.trim(), holderName.trim()) },
                enabled = !isSubmitting && bankCode.isNotBlank() && accountNo.isNotBlank() && holderName.isNotBlank(),
                shape = MaterialTheme.shapes.medium,
            ) { Text(stringResource(R.string.earnings_add_bank_submit)) }
            TextButton(onClick = onCancel) { Text(stringResource(R.string.earnings_cancel)) }
        }
    }
}

@Composable
private fun WithdrawForm(
    bankAccounts: List<BankAccount>,
    isSubmitting: Boolean,
    onSubmit: (String, Long) -> Unit,
    onCancel: () -> Unit,
) {
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
                onClick = { onSubmit(selectedBankAccountId, amountSen) },
                enabled = !isSubmitting && amountSen > 0,
                shape = MaterialTheme.shapes.medium,
            ) {
                if (isSubmitting) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.earnings_withdraw_submit))
                }
            }
            TextButton(onClick = onCancel, enabled = !isSubmitting) { Text(stringResource(R.string.earnings_cancel)) }
        }
    }
}

@Composable
private fun PayoutHistoryCard(payout: PayoutRequest) {
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
        payout.failureReason?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
}
