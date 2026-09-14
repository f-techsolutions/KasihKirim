@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.deliveries

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star as StarOutline
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.DisputeCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.NON_PROOF_DELIVERY_TRANSITIONS
import com.ftechsolutions.kasihkirim.domain.model.PROOF_DELIVERY_TRANSITIONS
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.domain.model.appliesTo
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge
import java.io.ByteArrayOutputStream

@Composable
fun DeliveriesScreen(
    vm: DeliveriesViewModel,
    currentUserId: String,
    myCarrierId: String?,
    roles: Set<UserRole>,
    onBack: () -> Unit,
) {
    val state by vm.state.collectAsState()

    // MediaStore's own camera app writes and returns a downscaled preview
    // Bitmap directly -- no FileProvider/Uri plumbing or CAMERA permission
    // declaration needed on this app's side, only on the camera app's.
    val cameraLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicturePreview(),
    ) { bitmap: Bitmap? ->
        if (bitmap != null) {
            val bytes = ByteArrayOutputStream()
                .apply { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, this) }
                .toByteArray()
            vm.submitProof(bytes)
        } else {
            vm.cancelProof()
        }
    }

    LaunchedEffect(state.pendingProof) {
        if (state.pendingProof != null) cameraLauncher.launch(null)
    }

    state.recordPurchaseDeliveryId?.let {
        RecordPurchaseDialog(
            onConfirm = vm::recordPurchase,
            onDismiss = vm::cancelRecordPurchase,
        )
    }

    state.openDisputeDeliveryId?.let {
        OpenDisputeDialog(
            category = state.disputeCategory,
            description = state.disputeDescription,
            onCategorySelected = vm::onDisputeCategorySelected,
            onDescriptionChange = vm::onDisputeDescriptionChange,
            onConfirm = vm::submitDispute,
            onDismiss = vm::cancelOpenDispute,
        )
    }

    state.rateDeliveryId?.let {
        RateDeliveryDialog(
            rating = state.ratingValue,
            comment = state.ratingComment,
            onRatingChange = vm::onRatingValueChange,
            onCommentChange = vm::onRatingCommentChange,
            onConfirm = vm::submitRating,
            onDismiss = vm::cancelRate,
        )
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.deliveries_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }

            if (state.deliveries.isEmpty() && !state.isLoading && state.error == null) {
                item { EmptyStateCard(stringResource(R.string.deliveries_empty)) }
            }
            items(state.deliveries, key = { it.id }) { delivery ->
                DeliveryCard(
                    delivery = delivery,
                    currentUserId = currentUserId,
                    myCarrierId = myCarrierId,
                    roles = roles,
                    isTransitioning = state.transitioningId == delivery.id,
                    alreadyReviewed = delivery.id in state.reviewedDeliveryIds,
                    onEvent = { event -> vm.transition(delivery.id, event) },
                    onRequestProof = { leg, event -> vm.requestProof(delivery.id, leg, event) },
                    onRequestRecordPurchase = { vm.requestRecordPurchase(delivery.id) },
                    onRequestOpenDispute = { vm.requestOpenDispute(delivery.id) },
                    onRequestRate = { vm.requestRate(delivery.id) },
                )
            }

            state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun DeliveryCard(
    delivery: Delivery,
    currentUserId: String,
    myCarrierId: String?,
    roles: Set<UserRole>,
    isTransitioning: Boolean,
    alreadyReviewed: Boolean,
    onEvent: (String) -> Unit,
    onRequestProof: (leg: String, event: String) -> Unit,
    onRequestRecordPurchase: () -> Unit,
    onRequestOpenDispute: () -> Unit,
    onRequestRate: () -> Unit,
) {
    val availableEvents = NON_PROOF_DELIVERY_TRANSITIONS
        .filter {
            it.fromStatus == delivery.status &&
                delivery.kirimType in it.applicableTypes &&
                it.allowedRoles.any { role -> role.appliesTo(delivery, currentUserId, myCarrierId, roles) }
        }
        // REPORT_FAILURE appears twice (pickup and delivery legs) but is
        // never simultaneously available from the same status -- this is
        // just distinct-by-event for safety against a future duplicate.
        .distinctBy { it.event }

    val availableProofEvents = PROOF_DELIVERY_TRANSITIONS
        .filter {
            it.fromStatus == delivery.status &&
                it.allowedRoles.any { role -> role.appliesTo(delivery, currentUserId, myCarrierId, roles) }
        }

    // RECORD_PURCHASE isn't in NON_PROOF_DELIVERY_TRANSITIONS: it needs an
    // amount from the carrier first, so it gets its own button + dialog
    // rather than firing an event directly like the plain status buttons.
    val showRecordPurchase = delivery.status == KirimStatus.PROCURING &&
        UserRole.CARRIER.appliesTo(delivery, currentUserId, myCarrierId, roles)

    // OPEN_DISPUTE isn't in NON_PROOF_DELIVERY_TRANSITIONS either: it needs a
    // category and description first (rpc_open_carrier_dispute, 0039), not a
    // bare fire-and-forget event. ref.delivery_transition_rules also allows
    // this for customer/seller, but this button is the carrier's own path
    // only -- a customer's marketplace order already has one in
    // BuyOrdersScreen (rpc_open_dispute) and a seller's in SalesScreen
    // (rpc_open_seller_dispute, 0038); a carrier had none at all until now.
    val showOpenDispute = delivery.status == KirimStatus.DELIVERED &&
        UserRole.CARRIER.appliesTo(delivery, currentUserId, myCarrierId, roles)

    // Whichever side I was on -- requester or carrier -- listMyDeliveries's
    // own RLS already scoped this card to a delivery I was a party to, so no
    // further role check is needed the way showOpenDispute's carrier-only
    // button needs one.
    val showRate = delivery.status == KirimStatus.COMPLETED && !alreadyReviewed

    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(delivery.itemDescription, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(delivery.status.labelMs, tone = delivery.status.tone())
        }
        Spacer(Modifier.height(4.dp))
        Text(
            delivery.referenceCode,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        delivery.carrierEarningSen?.let {
            Spacer(Modifier.height(2.dp))
            Text(stringResource(R.string.deliveries_carrier_earning, it.format()), style = MaterialTheme.typography.bodySmall)
        }
        // cod_amount_sen is 0 (not null) for a delivery with nothing to
        // collect -- a prepaid order, or a non-COD kirim -- so only a
        // strictly positive amount is worth a carrier's attention here.
        // Especially load-bearing for a PASARAN job, where this is the whole
        // order (goods + carriage) rpc_accept_offer already charged them to
        // collect, not just their own delivery_fee-sized earning above.
        if (delivery.codAmountSen > Sen.ZERO) {
            Spacer(Modifier.height(2.dp))
            Text(
                stringResource(R.string.deliveries_cod_amount, delivery.codAmountSen.format()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
            )
        }
        delivery.failureReason?.let {
            Spacer(Modifier.height(2.dp))
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }

        if (availableEvents.isNotEmpty() || availableProofEvents.isNotEmpty() ||
            showRecordPurchase || showOpenDispute || showRate
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (showRecordPurchase) {
                    Button(
                        onClick = onRequestRecordPurchase,
                        enabled = !isTransitioning,
                        shape = MaterialTheme.shapes.small,
                    ) {
                        if (isTransitioning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.deliveries_record_purchase))
                        }
                    }
                }
                availableEvents.forEach { rule ->
                    OutlinedButton(
                        onClick = { onEvent(rule.event) },
                        enabled = !isTransitioning,
                        shape = MaterialTheme.shapes.small,
                    ) {
                        if (isTransitioning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Text(rule.event.labelMs())
                        }
                    }
                }
                // Filled, not outlined -- these open the camera before
                // anything is submitted, a heavier action than the plain
                // status buttons above.
                availableProofEvents.forEach { rule ->
                    Button(
                        onClick = { onRequestProof(rule.leg, rule.event) },
                        enabled = !isTransitioning,
                        shape = MaterialTheme.shapes.small,
                    ) {
                        if (isTransitioning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(rule.event.proofLabelRes()))
                        }
                    }
                }
                if (showOpenDispute) {
                    OutlinedButton(
                        onClick = onRequestOpenDispute,
                        enabled = !isTransitioning,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                        shape = MaterialTheme.shapes.small,
                    ) {
                        if (isTransitioning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.deliveries_report_problem))
                        }
                    }
                }
                if (showRate) {
                    Button(
                        onClick = onRequestRate,
                        enabled = !isTransitioning,
                        shape = MaterialTheme.shapes.small,
                    ) {
                        if (isTransitioning) {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.deliveries_rate))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun RecordPurchaseDialog(onConfirm: (actualGoodsSen: Long) -> Unit, onDismiss: () -> Unit) {
    var amountRinggit by remember { mutableStateOf("") }
    // Mirrors the RM-to-sen parsing already used by SalesViewModel/AdminScreen.
    val amountSen = amountRinggit.toDoubleOrNull()?.takeIf { it > 0 }?.let { (it * 100).toLong() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.deliveries_record_purchase_title)) },
        text = {
            OutlinedTextField(
                value = amountRinggit,
                onValueChange = { amountRinggit = it },
                label = { Text(stringResource(R.string.deliveries_record_purchase_amount_label)) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
        },
        confirmButton = {
            TextButton(onClick = { amountSen?.let(onConfirm) }, enabled = amountSen != null) {
                Text(stringResource(R.string.deliveries_record_purchase_submit))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.deliveries_record_purchase_cancel)) }
        },
    )
}

@Composable
private fun OpenDisputeDialog(
    category: DisputeCategory,
    description: String,
    onCategorySelected: (DisputeCategory) -> Unit,
    onDescriptionChange: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.deliveries_open_dispute_title)) },
        text = {
            Column {
                Text(stringResource(R.string.deliveries_open_dispute_category), style = MaterialTheme.typography.labelLarge)
                Spacer(Modifier.height(4.dp))
                DisputeCategoryChips(category, onCategorySelected)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = description,
                    onValueChange = onDescriptionChange,
                    label = { Text(stringResource(R.string.deliveries_open_dispute_description)) },
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = description.trim().length >= 10) {
                Text(stringResource(R.string.deliveries_open_dispute_submit))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.deliveries_record_purchase_cancel)) }
        },
    )
}

/** rpc_submit_review (0044). A 1-5 star picker plus an optional comment --
 *  submitting again while the dialog is reopened for the same delivery edits
 *  the caller's own prior rating (the server enforces the 24h edit window,
 *  this dialog doesn't need to know where that window stands). */
@Composable
private fun RateDeliveryDialog(
    rating: Int,
    comment: String,
    onRatingChange: (Int) -> Unit,
    onCommentChange: (String) -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.deliveries_rate_title)) },
        text = {
            Column {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    (1..5).forEach { star ->
                        IconButton(onClick = { onRatingChange(star) }) {
                            Icon(
                                imageVector = if (star <= rating) Icons.Filled.Star else StarOutline,
                                contentDescription = stringResource(R.string.deliveries_rate_star, star),
                                tint = if (star <= rating) MaterialTheme.colorScheme.primary
                                       else MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = comment,
                    onValueChange = onCommentChange,
                    label = { Text(stringResource(R.string.deliveries_rate_comment_label)) },
                    minLines = 2,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm) { Text(stringResource(R.string.deliveries_rate_submit)) }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.deliveries_record_purchase_cancel)) }
        },
    )
}

/** Mirrors SalesScreen's own DisputeCategoryChips/BuyOrdersScreen's
 *  FlowRowChips for the seller's and buyer's own dispute forms -- same
 *  DisputeCategory enum, same two-row wrapping layout, now also offered to a
 *  carrier filing via rpc_open_carrier_dispute (0039). */
@Composable
private fun DisputeCategoryChips(selected: DisputeCategory, onSelect: (DisputeCategory) -> Unit) {
    val categories = DisputeCategory.entries
    val (first, second) = categories.chunked((categories.size + 1) / 2).let { it[0] to (it.getOrNull(1) ?: emptyList()) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            first.forEach { category ->
                FilterChip(
                    selected = selected == category,
                    onClick = { onSelect(category) },
                    label = { Text(category.labelMs) },
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            second.forEach { category ->
                FilterChip(
                    selected = selected == category,
                    onClick = { onSelect(category) },
                    label = { Text(category.labelMs) },
                )
            }
        }
    }
}

private fun String.proofLabelRes(): Int = when (this) {
    "CONFIRM_PICKUP" -> R.string.deliveries_confirm_pickup
    "CONFIRM_DELIVERY" -> R.string.deliveries_confirm_delivery
    "CONFIRM_RETURN" -> R.string.deliveries_confirm_return
    else -> R.string.deliveries_confirm_pickup
}

private fun KirimStatus.tone(): BadgeTone = when {
    this == KirimStatus.DELIVERED || this == KirimStatus.COMPLETED -> BadgeTone.POSITIVE
    isFailure || this == KirimStatus.CANCELLED || this == KirimStatus.EXPIRED -> BadgeTone.ERROR
    this == KirimStatus.DRAFT || this == KirimStatus.POSTED -> BadgeTone.NEUTRAL
    else -> BadgeTone.WARNING
}

private fun String.labelMs(): String = when (this) {
    "START_PROCUREMENT" -> "Mula Beli"
    "GO_TO_PICKUP" -> "Menuju Ambil"
    "CANCEL" -> "Batal"
    "PROCUREMENT_FAILED" -> "Belian Gagal"
    "REPORT_FAILURE" -> "Lapor Gagal"
    "RETURN" -> "Pulangkan Barang"
    "DEPART" -> "Berlepas"
    "ARRIVE_HUB" -> "Sampai Hab"
    "LEAVE_HUB" -> "Tinggalkan Hab"
    "START_DELIVERY" -> "Mula Hantar"
    "RETRY" -> "Cuba Lagi"
    "CONFIRM_RECEIPT" -> "Sahkan Terima"
    else -> this
}
