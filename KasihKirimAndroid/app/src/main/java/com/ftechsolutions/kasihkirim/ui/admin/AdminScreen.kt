@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.admin

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
import com.ftechsolutions.kasihkirim.domain.model.CarrierApplication
import com.ftechsolutions.kasihkirim.domain.model.Dispute
import com.ftechsolutions.kasihkirim.domain.model.DisputeStatus
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
