@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.admin

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.AccountStatus
import com.ftechsolutions.kasihkirim.domain.model.AdminAccount
import com.ftechsolutions.kasihkirim.domain.model.AdminPayout
import com.ftechsolutions.kasihkirim.domain.model.CarrierApplication
import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
import com.ftechsolutions.kasihkirim.domain.model.PayoutStatus
import com.ftechsolutions.kasihkirim.domain.model.ProductReview
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.SellerApplication
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun AdminScreen(vm: AdminViewModel) {
    val state by vm.state.collectAsState()

    // See BoardScreen's identical comment: init{}'s one-shot load() doesn't
    // refire when this tab is re-entered without this.
    LaunchedEffect(Unit) { vm.load() }

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 20.dp)) {
            Spacer(Modifier.height(12.dp))
            ScreenHeader(stringResource(R.string.admin_title))
        }

        TabRow(selectedTabIndex = state.queue.ordinal) {
            Tab(
                selected = state.queue == AdminQueue.SELLERS,
                onClick = { vm.selectQueue(AdminQueue.SELLERS) },
                text = { Text(tabLabel(R.string.admin_tab_sellers, state.sellers.size)) },
            )
            Tab(
                selected = state.queue == AdminQueue.CARRIERS,
                onClick = { vm.selectQueue(AdminQueue.CARRIERS) },
                text = { Text(tabLabel(R.string.admin_tab_carriers, state.carriers.size)) },
            )
            Tab(
                selected = state.queue == AdminQueue.PRODUCTS,
                onClick = { vm.selectQueue(AdminQueue.PRODUCTS) },
                text = { Text(tabLabel(R.string.admin_tab_products, state.products.size)) },
            )
            Tab(
                selected = state.queue == AdminQueue.DISPUTES,
                onClick = { vm.selectQueue(AdminQueue.DISPUTES) },
                text = { Text(tabLabel(R.string.admin_tab_disputes, state.disputes.size)) },
            )
            Tab(
                selected = state.queue == AdminQueue.ACCOUNTS,
                onClick = { vm.selectQueue(AdminQueue.ACCOUNTS) },
                text = { Text(stringResource(R.string.admin_tab_accounts)) },
            )
            Tab(
                selected = state.queue == AdminQueue.PAYOUTS,
                onClick = { vm.selectQueue(AdminQueue.PAYOUTS) },
                text = { Text(tabLabel(R.string.admin_tab_payouts, state.payouts.size)) },
            )
        }

        if (state.queue == AdminQueue.ACCOUNTS) {
            Column(Modifier.padding(horizontal = 20.dp)) {
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = state.accountQuery,
                    onValueChange = vm::onAccountQueryChange,
                    label = { Text(stringResource(R.string.admin_account_search_label)) },
                    placeholder = { Text(stringResource(R.string.admin_account_search_hint)) },
                    singleLine = true,
                    shape = MaterialTheme.shapes.small,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { vm.searchAccounts() }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        Box(Modifier.weight(1f)) {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item { Spacer(Modifier.height(4.dp)) }

                state.notice?.let { notice ->
                    item {
                        AppCard {
                            Text(
                                stringResource(
                                    when (notice) {
                                        AdminNotice.SELLER_APPROVED_MUST_RESIGN ->
                                            R.string.admin_notice_seller_must_resign
                                        AdminNotice.CARRIER_APPROVED_MUST_RESIGN ->
                                            R.string.admin_notice_carrier_must_resign
                                    },
                                ),
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            TextButton(onClick = vm::dismissNotice) {
                                Text(stringResource(R.string.admin_dismiss))
                            }
                        }
                    }
                }

                when (state.queue) {
                    AdminQueue.SELLERS -> {
                        if (state.sellers.isEmpty() && !state.isLoading && state.error == null) {
                            item { EmptyStateCard(stringResource(R.string.admin_no_sellers)) }
                        }
                        items(state.sellers, key = { it.id }) { application ->
                            SellerApplicationCard(
                                application = application,
                                isDeciding = state.decidingId == application.id,
                                onApprove = { vm.decideSeller(application.id, SellerStatus.APPROVED) },
                                onReject = { reason ->
                                    vm.decideSeller(application.id, SellerStatus.REJECTED, reason)
                                },
                            )
                        }
                    }

                    AdminQueue.CARRIERS -> {
                        if (state.carriers.isEmpty() && !state.isLoading && state.error == null) {
                            item { EmptyStateCard(stringResource(R.string.admin_no_carriers)) }
                        }
                        items(state.carriers, key = { it.id }) { application ->
                            CarrierApplicationCard(
                                application = application,
                                isDeciding = state.decidingId == application.id,
                                onApprove = { vm.decideCarrier(application.id, SellerStatus.APPROVED) },
                                onReject = { reason ->
                                    vm.decideCarrier(application.id, SellerStatus.REJECTED, reason)
                                },
                            )
                        }
                    }

                    AdminQueue.PRODUCTS -> {
                        if (state.products.isEmpty() && !state.isLoading && state.error == null) {
                            item { EmptyStateCard(stringResource(R.string.admin_no_products)) }
                        }
                        items(state.products, key = { it.id }) { product ->
                            ProductReviewCard(
                                product = product,
                                isDeciding = state.decidingId == product.id,
                                onApprove = { vm.decideProduct(product.id, ProductStatus.ACTIVE) },
                                onReject = { reason ->
                                    vm.decideProduct(product.id, ProductStatus.REJECTED, reason)
                                },
                            )
                        }
                    }

                    AdminQueue.DISPUTES -> {
                        if (state.disputes.isEmpty() && !state.isLoading && state.error == null) {
                            item { EmptyStateCard(stringResource(R.string.admin_no_disputes)) }
                        }
                        items(state.disputes, key = { it.id }) { dispute ->
                            DisputeCard(
                                dispute = dispute,
                                isDeciding = state.decidingId == dispute.id,
                                onResolve = { status, note, refundSen ->
                                    vm.resolveDispute(dispute.id, status, note, refundSen)
                                },
                            )
                        }
                    }

                    AdminQueue.ACCOUNTS -> {
                        if (state.accounts.isEmpty() && !state.isSearchingAccounts && state.error == null &&
                            state.accountQuery.isNotBlank()
                        ) {
                            item { EmptyStateCard(stringResource(R.string.admin_no_accounts)) }
                        }
                        items(state.accounts, key = { it.id }) { account ->
                            AccountCard(
                                account = account,
                                isDeciding = state.decidingId == account.id,
                                onSetStatus = { status, reason -> vm.setAccountStatus(account.id, status, reason) },
                            )
                        }
                    }

                    AdminQueue.PAYOUTS -> {
                        if (state.payouts.isEmpty() && !state.isLoading && state.error == null) {
                            item { EmptyStateCard(stringResource(R.string.admin_no_payouts)) }
                        }
                        items(state.payouts, key = { it.id }) { payout ->
                            PayoutCard(
                                payout = payout,
                                isDeciding = state.decidingId == payout.id,
                                onReview = { approve, reason -> vm.reviewPayout(payout.id, approve, reason) },
                                onApprove = { approve, reason -> vm.approvePayout(payout.id, approve, reason) },
                                onMarkPaid = { providerRef -> vm.markPayoutPaid(payout.id, providerRef) },
                                onMarkFailed = { reason -> vm.markPayoutFailed(payout.id, reason) },
                            )
                        }
                    }
                }

                state.error?.let {
                    item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }
                }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }
}

@Composable
private fun tabLabel(labelRes: Int, count: Int): String =
    if (count > 0) "${stringResource(labelRes)} ($count)" else stringResource(labelRes)

@Composable
private fun SellerApplicationCard(
    application: SellerApplication,
    isDeciding: Boolean,
    onApprove: () -> Unit,
    onReject: (String?) -> Unit,
) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                application.businessName,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            StatusBadge(application.status.labelMs, tone = BadgeTone.WARNING)
        }
        application.ssmRegNo?.let {
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.admin_ssm_prefix, it),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        application.reviewNote?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DecisionRow(
            isDeciding = isDeciding,
            approveLabel = stringResource(R.string.admin_approve),
            rejectLabel = stringResource(R.string.admin_reject),
            onApprove = onApprove,
            onReject = onReject,
        )
    }
}

@Composable
private fun CarrierApplicationCard(
    application: CarrierApplication,
    isDeciding: Boolean,
    onApprove: () -> Unit,
    onReject: (String?) -> Unit,
) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                application.homeCommunityName ?: stringResource(R.string.admin_carrier_unknown_community),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            StatusBadge(application.status.labelMs, tone = BadgeTone.WARNING)
        }
        application.reviewNote?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DecisionRow(
            isDeciding = isDeciding,
            approveLabel = stringResource(R.string.admin_approve),
            rejectLabel = stringResource(R.string.admin_reject),
            onApprove = onApprove,
            onReject = onReject,
        )
    }
}

@Composable
private fun ProductReviewCard(
    product: ProductReview,
    isDeciding: Boolean,
    onApprove: () -> Unit,
    onReject: (String?) -> Unit,
) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(product.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(product.status.labelMs, tone = BadgeTone.WARNING)
        }
        Spacer(Modifier.height(4.dp))
        Text(
            "${product.priceSen.format()} / ${product.unit}",
            style = MaterialTheme.typography.bodyMedium,
        )
        if (product.sellerName.isNotBlank()) {
            Text(
                product.sellerName,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        product.description?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DecisionRow(
            isDeciding = isDeciding,
            approveLabel = stringResource(R.string.admin_publish),
            rejectLabel = stringResource(R.string.admin_reject),
            onApprove = onApprove,
            onReject = onReject,
        )
    }
}

@Composable
private fun DisputeCard(
    dispute: Dispute,
    isDeciding: Boolean,
    onResolve: (DisputeStatus, String?, Long) -> Unit,
) {
    var open by remember(dispute.id) { mutableStateOf(false) }
    var note by remember(dispute.id) { mutableStateOf("") }
    var refundRinggit by remember(dispute.id) { mutableStateOf("") }

    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(dispute.category, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(dispute.status.labelMs, tone = BadgeTone.ERROR)
        }
        Spacer(Modifier.height(4.dp))
        Text(dispute.description, style = MaterialTheme.typography.bodyMedium)
        if (dispute.holdsEscrow) {
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.admin_dispute_holds_escrow),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }

        if (!open) {
            TextButton(onClick = { open = true }, enabled = !isDeciding) {
                Text(stringResource(R.string.admin_resolve))
            }
        } else {
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = note,
                onValueChange = { note = it },
                label = { Text(stringResource(R.string.admin_resolution_note)) },
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = refundRinggit,
                onValueChange = { refundRinggit = it },
                label = { Text(stringResource(R.string.admin_refund_amount)) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                stringResource(R.string.admin_refund_recorded_only),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Spacer(Modifier.height(8.dp))
            val refundSen = (refundRinggit.toDoubleOrNull()?.takeIf { it > 0 } ?: 0.0)
                .let { (it * 100).toLong() }
            val trimmedNote = note.trim().takeIf { it.isNotEmpty() }

            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Button(
                    onClick = { onResolve(DisputeStatus.RESOLVED_REFUND_FULL, trimmedNote, refundSen) },
                    enabled = !isDeciding,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.admin_dispute_refund)) }
                OutlinedButton(
                    onClick = { onResolve(DisputeStatus.RESOLVED_REJECTED, trimmedNote, 0) },
                    enabled = !isDeciding,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.admin_dispute_reject_claim)) }
                TextButton(
                    onClick = { onResolve(DisputeStatus.UNDER_REVIEW, trimmedNote, 0) },
                    enabled = !isDeciding,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.admin_dispute_mark_reviewing)) }
                TextButton(onClick = { open = false }, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.admin_cancel))
                }
            }
        }
    }
}

/** Unlike the review queues above, this isn't a binary approve/reject decision
 *  and the row never leaves the list on its own -- a search result stays
 *  visible after a status change, just re-labelled, since the admin may act
 *  on it again (e.g. restore right after a mistaken suspend). */
@Composable
private fun AccountCard(
    account: AdminAccount,
    isDeciding: Boolean,
    onSetStatus: (AccountStatus, String?) -> Unit,
) {
    var pendingAction by remember(account.id) { mutableStateOf<AccountStatus?>(null) }
    var reason by remember(account.id) { mutableStateOf("") }

    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                account.displayName ?: account.fullName ?: account.phone,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            StatusBadge(
                account.status.labelMs,
                tone = when (account.status) {
                    AccountStatus.ACTIVE -> BadgeTone.POSITIVE
                    AccountStatus.SUSPENDED, AccountStatus.BANNED -> BadgeTone.ERROR
                    AccountStatus.PENDING, AccountStatus.DELETED -> BadgeTone.WARNING
                },
            )
        }
        Spacer(Modifier.height(4.dp))
        Text(account.phone, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        account.suspendedReason?.let {
            Spacer(Modifier.height(4.dp))
            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }

        Spacer(Modifier.height(10.dp))
        val action = pendingAction
        if (action != null) {
            OutlinedTextField(
                value = reason,
                onValueChange = { reason = it },
                label = {
                    Text(
                        stringResource(
                            if (action == AccountStatus.BANNED) R.string.admin_account_ban_reason
                            else R.string.admin_account_suspend_reason,
                        ),
                    )
                },
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
                minLines = 2,
            )
            Spacer(Modifier.height(6.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = {
                        onSetStatus(action, reason.trim().takeIf { it.isNotEmpty() })
                        pendingAction = null
                        reason = ""
                    },
                    enabled = !isDeciding,
                    shape = MaterialTheme.shapes.medium,
                ) { Text(stringResource(R.string.admin_account_confirm)) }
                TextButton(onClick = { pendingAction = null; reason = "" }) {
                    Text(stringResource(R.string.admin_cancel))
                }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (account.status == AccountStatus.SUSPENDED || account.status == AccountStatus.BANNED) {
                    Button(
                        onClick = { onSetStatus(AccountStatus.ACTIVE, null) },
                        enabled = !isDeciding,
                        shape = MaterialTheme.shapes.medium,
                    ) {
                        if (isDeciding) {
                            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.admin_account_restore))
                        }
                    }
                } else {
                    OutlinedButton(
                        onClick = { pendingAction = AccountStatus.SUSPENDED },
                        enabled = !isDeciding,
                        shape = MaterialTheme.shapes.medium,
                    ) { Text(stringResource(R.string.admin_account_suspend)) }
                    TextButton(onClick = { pendingAction = AccountStatus.BANNED }, enabled = !isDeciding) {
                        Text(stringResource(R.string.admin_account_ban))
                    }
                }
            }
        }
    }
}

/** One card, three different action shapes depending on status --
 *  REQUESTED/UNDER_REVIEW are still a review/approve decision (DecisionRow
 *  fits), but APPROVED becomes "pay or fail", which isn't an approve/reject
 *  choice at all, so it gets its own row instead of forcing DecisionRow's
 *  labels to mean something they don't. */
@Composable
private fun PayoutCard(
    payout: AdminPayout,
    isDeciding: Boolean,
    onReview: (Boolean, String?) -> Unit,
    onApprove: (Boolean, String?) -> Unit,
    onMarkPaid: (String?) -> Unit,
    onMarkFailed: (String) -> Unit,
) {
    var failing by remember(payout.id) { mutableStateOf(false) }
    var reason by remember(payout.id) { mutableStateOf("") }
    var providerRef by remember(payout.id) { mutableStateOf("") }

    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                payout.payeeLabel ?: payout.payeeType,
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            StatusBadge(payout.status.labelMs, tone = BadgeTone.WARNING)
        }
        Spacer(Modifier.height(4.dp))
        Text(payout.amountSen.format(), style = MaterialTheme.typography.bodyMedium)
        Text(
            "${payout.bankCode} •••• ${payout.accountNoLast4} (${payout.holderName})",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        when (payout.status) {
            PayoutStatus.REQUESTED -> DecisionRow(
                isDeciding = isDeciding,
                approveLabel = stringResource(R.string.admin_payout_send_to_review),
                rejectLabel = stringResource(R.string.admin_reject),
                onApprove = { onReview(true, null) },
                onReject = { r -> onReview(false, r) },
            )

            PayoutStatus.UNDER_REVIEW -> DecisionRow(
                isDeciding = isDeciding,
                approveLabel = stringResource(R.string.admin_approve),
                rejectLabel = stringResource(R.string.admin_reject),
                onApprove = { onApprove(true, null) },
                onReject = { r -> onApprove(false, r) },
            )

            PayoutStatus.APPROVED -> {
                Spacer(Modifier.height(10.dp))
                if (failing) {
                    OutlinedTextField(
                        value = reason,
                        onValueChange = { reason = it },
                        label = { Text(stringResource(R.string.admin_payout_fail_reason)) },
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth(),
                        minLines = 2,
                    )
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(
                            onClick = { onMarkFailed(reason.trim()); failing = false },
                            enabled = !isDeciding && reason.isNotBlank(),
                            shape = MaterialTheme.shapes.medium,
                        ) { Text(stringResource(R.string.admin_confirm_reject)) }
                        TextButton(onClick = { failing = false }) { Text(stringResource(R.string.admin_cancel)) }
                    }
                } else {
                    OutlinedTextField(
                        value = providerRef,
                        onValueChange = { providerRef = it },
                        label = { Text(stringResource(R.string.admin_payout_provider_ref)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(6.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Button(
                            onClick = { onMarkPaid(providerRef.trim().takeIf { it.isNotEmpty() }) },
                            enabled = !isDeciding,
                            shape = MaterialTheme.shapes.medium,
                        ) {
                            if (isDeciding) {
                                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            } else {
                                Text(stringResource(R.string.admin_payout_mark_paid))
                            }
                        }
                        TextButton(onClick = { failing = true }, enabled = !isDeciding) {
                            Text(stringResource(R.string.admin_payout_mark_failed))
                        }
                    }
                }
            }

            else -> Unit
        }
    }
}

/** Approve is one tap; rejecting asks why first, so the applicant is told
 *  something they can act on rather than just being refused. */
@Composable
private fun DecisionRow(
    isDeciding: Boolean,
    approveLabel: String,
    rejectLabel: String,
    onApprove: () -> Unit,
    onReject: (String?) -> Unit,
) {
    var rejecting by remember { mutableStateOf(false) }
    var reason by remember { mutableStateOf("") }

    Spacer(Modifier.height(10.dp))
    if (rejecting) {
        OutlinedTextField(
            value = reason,
            onValueChange = { reason = it },
            label = { Text(stringResource(R.string.admin_reject_reason)) },
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
        )
        Spacer(Modifier.height(6.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = {
                    onReject(reason.trim().takeIf { it.isNotEmpty() })
                    rejecting = false
                },
                enabled = !isDeciding,
                shape = MaterialTheme.shapes.medium,
            ) { Text(stringResource(R.string.admin_confirm_reject)) }
            TextButton(onClick = { rejecting = false }) {
                Text(stringResource(R.string.admin_cancel))
            }
        }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(
                onClick = onApprove,
                enabled = !isDeciding,
                shape = MaterialTheme.shapes.medium,
            ) {
                if (isDeciding) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(approveLabel)
                }
            }
            TextButton(onClick = { rejecting = true }, enabled = !isDeciding) { Text(rejectLabel) }
        }
    }
}
