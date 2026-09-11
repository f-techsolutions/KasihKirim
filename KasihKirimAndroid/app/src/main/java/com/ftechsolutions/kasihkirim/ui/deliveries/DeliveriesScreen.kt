@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.deliveries

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.NON_PROOF_DELIVERY_TRANSITIONS
import com.ftechsolutions.kasihkirim.domain.model.PROOF_DELIVERY_TRANSITIONS
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge
import java.io.ByteArrayOutputStream

@Composable
fun DeliveriesScreen(vm: DeliveriesViewModel, roles: Set<UserRole>, onBack: () -> Unit) {
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

            if (state.deliveries.isEmpty() && !state.isLoading) {
                item { EmptyStateCard(stringResource(R.string.deliveries_empty)) }
            }
            items(state.deliveries, key = { it.id }) { delivery ->
                DeliveryCard(
                    delivery = delivery,
                    roles = roles,
                    isTransitioning = state.transitioningId == delivery.id,
                    onEvent = { event -> vm.transition(delivery.id, event) },
                    onRequestProof = { leg, event -> vm.requestProof(delivery.id, leg, event) },
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
    roles: Set<UserRole>,
    isTransitioning: Boolean,
    onEvent: (String) -> Unit,
    onRequestProof: (leg: String, event: String) -> Unit,
) {
    val availableEvents = NON_PROOF_DELIVERY_TRANSITIONS
        .filter {
            it.fromStatus == delivery.status &&
                delivery.kirimType in it.applicableTypes &&
                it.allowedRoles.any { role -> role in roles }
        }
        // REPORT_FAILURE appears twice (pickup and delivery legs) but is
        // never simultaneously available from the same status -- this is
        // just distinct-by-event for safety against a future duplicate.
        .distinctBy { it.event }

    val availableProofEvents = PROOF_DELIVERY_TRANSITIONS
        .filter { it.fromStatus == delivery.status && it.allowedRoles.any { role -> role in roles } }

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

        if (availableEvents.isNotEmpty() || availableProofEvents.isNotEmpty()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
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
    "DEPART" -> "Berlepas"
    "ARRIVE_HUB" -> "Sampai Hab"
    "LEAVE_HUB" -> "Tinggalkan Hab"
    "START_DELIVERY" -> "Mula Hantar"
    "RETRY" -> "Cuba Lagi"
    "CONFIRM_RECEIPT" -> "Sahkan Terima"
    else -> this
}
