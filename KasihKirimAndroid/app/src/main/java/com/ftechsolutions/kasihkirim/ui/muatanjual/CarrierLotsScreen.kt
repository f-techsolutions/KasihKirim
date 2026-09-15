@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.muatanjual

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.CarrierLot
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.LotStatus
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualOnboardingStatus
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge
import java.io.ByteArrayOutputStream
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/**
 * A carrier's own Muatan Jual lots (Phase 3, 0047_muatan_jual_lot_lifecycle.
 * sql). Reached from Profile, not a bottom tab -- CARRIER's tab row is
 * already at six entries (Destinations.kt), the same reasoning
 * PROMOTIONS_ROUTE/CARRIER_APPLICATION_ROUTE already live off Profile
 * instead of crowding it further.
 *
 * ref.compliance_state.status stays NOT_READY -- every action here still
 * refuses server-side (rpc_create_lot's own internal.fn_marketplace_gate
 * call). This screen exists so a carrier can complete onboarding and
 * prepare listings ahead of go-live, not because the marketplace is live.
 */
@Composable
fun CarrierLotsScreen(vm: CarrierLotsViewModel, onBack: () -> Unit, onApplyAsSeller: () -> Unit) {
    val state by vm.state.collectAsState()

    LaunchedEffect(Unit) { vm.load() }

    val receiptCameraLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicturePreview(),
    ) { bitmap: Bitmap? ->
        if (bitmap != null) {
            val bytes = ByteArrayOutputStream()
                .apply { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, this) }
                .toByteArray()
            vm.captureReceipt(bytes)
        }
    }

    if (state.showCreateForm) {
        CreateLotDialog(
            state = state,
            onTitleChange = vm::onCreateTitleChange,
            onCategoryChange = vm::onCreateCategoryChange,
            onQtyChange = vm::onCreateQtyChange,
            onUnitChange = vm::onCreateUnitChange,
            onCostBasisChange = vm::onCreateCostBasisChange,
            onPriceChange = vm::onCreatePriceChange,
            onToggleHandlingFlag = vm::onToggleHandlingFlag,
            onCaptureReceipt = { receiptCameraLauncher.launch(null) },
            onConfirm = vm::submitCreate,
            onDismiss = vm::closeCreateForm,
        )
    }

    state.attachingLotId?.let {
        AttachTripDialog(
            trips = state.attachableTrips,
            onSelect = vm::attachToTrip,
            onDismiss = vm::cancelAttach,
        )
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.carrier_lots_title)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }

            val seller = state.seller
            when {
                state.isLoading -> item {
                    Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator()
                    }
                }
                seller == null -> item {
                    OnboardingCard(
                        title = stringResource(R.string.carrier_lots_apply_title),
                        body = stringResource(R.string.carrier_lots_apply_body),
                        actionLabel = stringResource(R.string.carrier_lots_apply_action),
                        onAction = onApplyAsSeller,
                    )
                }
                seller.onboardingStatus == MuatanJualOnboardingStatus.APPROVED -> item {
                    OnboardingCard(
                        title = stringResource(R.string.carrier_lots_accept_title),
                        body = stringResource(R.string.carrier_lots_accept_body),
                        actionLabel = stringResource(R.string.carrier_lots_accept_action),
                        isBusy = state.isAcceptingTerms,
                        onAction = vm::acceptTerms,
                    )
                }
                seller.onboardingStatus != MuatanJualOnboardingStatus.ACTIVE -> item {
                    EmptyStateCard(
                        title = seller.onboardingStatus.labelMs,
                        hint = stringResource(R.string.carrier_lots_waiting_hint),
                    )
                }
                else -> {
                    item {
                        Button(onClick = vm::openCreateForm, shape = MaterialTheme.shapes.small) {
                            Text(stringResource(R.string.carrier_lots_create))
                        }
                    }
                    if (state.lots.isEmpty()) {
                        item { EmptyStateCard(stringResource(R.string.carrier_lots_empty)) }
                    }
                    items(state.lots, key = { it.id }) { lot ->
                        LotRow(
                            lot = lot,
                            isBusy = state.busyLotId == lot.id,
                            onAttach = { vm.requestAttach(lot.id) },
                            onWithdraw = { vm.withdrawLot(lot.id) },
                        )
                    }
                }
            }

            state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun OnboardingCard(
    title: String,
    body: String,
    actionLabel: String,
    isBusy: Boolean = false,
    onAction: () -> Unit,
) {
    AppCard {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(4.dp))
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(10.dp))
        Button(onClick = onAction, enabled = !isBusy, shape = MaterialTheme.shapes.small) {
            if (isBusy) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            else Text(actionLabel)
        }
    }
}

@Composable
private fun LotRow(lot: CarrierLot, isBusy: Boolean, onAttach: () -> Unit, onWithdraw: () -> Unit) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(lot.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(lot.status.labelMs, tone = lot.status.tone())
        }
        Spacer(Modifier.height(4.dp))
        Text(
            stringResource(R.string.carrier_lots_price_and_qty, lot.pricePerUnitSen.format(), lot.unit, formatQty(lot.qtyTotal - lot.qtyReserved - lot.qtySold)),
            style = MaterialTheme.typography.bodyMedium,
        )
        Text(
            stringResource(R.string.carrier_lots_cost_basis, lot.costBasisSen.format()),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (lot.handlingFlags.isNotEmpty()) {
            Spacer(Modifier.height(2.dp))
            Text(
                lot.handlingFlags.joinToString(" · ") { it.labelMs },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        val showAttach = lot.status == LotStatus.DRAFT
        val showWithdraw = lot.status == LotStatus.DRAFT || lot.status == LotStatus.ACTIVE
        if (showAttach || showWithdraw) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (showAttach) {
                    Button(onClick = onAttach, enabled = !isBusy, shape = MaterialTheme.shapes.small) {
                        if (isBusy) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        else Text(stringResource(R.string.carrier_lots_attach))
                    }
                }
                if (showWithdraw) {
                    OutlinedButton(
                        onClick = onWithdraw,
                        enabled = !isBusy,
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
                        shape = MaterialTheme.shapes.small,
                    ) {
                        if (isBusy) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        else Text(stringResource(R.string.carrier_lots_withdraw))
                    }
                }
            }
        }
    }
}

@Composable
private fun CreateLotDialog(
    state: CarrierLotsUiState,
    onTitleChange: (String) -> Unit,
    onCategoryChange: (KirimCategory) -> Unit,
    onQtyChange: (String) -> Unit,
    onUnitChange: (String) -> Unit,
    onCostBasisChange: (String) -> Unit,
    onPriceChange: (String) -> Unit,
    onToggleHandlingFlag: (HandlingFlag) -> Unit,
    onCaptureReceipt: () -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val canSubmit = state.createTitle.trim().length >= 3 &&
        state.createQtyText.toDoubleOrNull()?.let { it > 0 } == true &&
        state.createCostBasisRinggitText.toDoubleOrNull() != null &&
        state.createPriceRinggitText.toDoubleOrNull()?.let { it > 0 } == true &&
        state.createReceiptPath != null &&
        !state.isSubmittingCreate

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.carrier_lots_create_title)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(
                    value = state.createTitle, onValueChange = onTitleChange,
                    label = { Text(stringResource(R.string.carrier_lots_field_title)) },
                    singleLine = true, shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth(),
                )
                Text(stringResource(R.string.carrier_lots_field_category), style = MaterialTheme.typography.labelLarge)
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    KirimCategory.entries.forEach { category ->
                        FilterChip(
                            selected = state.createCategory == category,
                            onClick = { onCategoryChange(category) },
                            label = { Text(category.nameMs) },
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        value = state.createQtyText, onValueChange = onQtyChange,
                        label = { Text(stringResource(R.string.carrier_lots_field_qty)) },
                        singleLine = true, shape = MaterialTheme.shapes.small,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                        modifier = Modifier.weight(1f),
                    )
                    OutlinedTextField(
                        value = state.createUnit, onValueChange = onUnitChange,
                        label = { Text(stringResource(R.string.carrier_lots_field_unit)) },
                        singleLine = true, shape = MaterialTheme.shapes.small,
                        modifier = Modifier.weight(1f),
                    )
                }
                OutlinedTextField(
                    value = state.createCostBasisRinggitText, onValueChange = onCostBasisChange,
                    label = { Text(stringResource(R.string.carrier_lots_field_cost_basis)) },
                    singleLine = true, shape = MaterialTheme.shapes.small,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = state.createPriceRinggitText, onValueChange = onPriceChange,
                    label = { Text(stringResource(R.string.carrier_lots_field_price)) },
                    singleLine = true, shape = MaterialTheme.shapes.small,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(stringResource(R.string.carrier_lots_field_handling), style = MaterialTheme.typography.labelLarge)
                val flags = HandlingFlag.entries
                val (firstFlags, secondFlags) = flags.chunked((flags.size + 1) / 2)
                    .let { it[0] to (it.getOrNull(1) ?: emptyList()) }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    firstFlags.forEach { flag ->
                        FilterChip(
                            selected = flag in state.createHandlingFlags,
                            onClick = { onToggleHandlingFlag(flag) },
                            label = { Text(flag.labelMs) },
                        )
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    secondFlags.forEach { flag ->
                        FilterChip(
                            selected = flag in state.createHandlingFlags,
                            onClick = { onToggleHandlingFlag(flag) },
                            label = { Text(flag.labelMs) },
                        )
                    }
                }
                OutlinedButton(onClick = onCaptureReceipt, enabled = !state.isUploadingReceipt, shape = MaterialTheme.shapes.small) {
                    if (state.isUploadingReceipt) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    } else {
                        Text(
                            if (state.createReceiptPath != null) stringResource(R.string.carrier_lots_receipt_captured)
                            else stringResource(R.string.carrier_lots_receipt_capture),
                        )
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onConfirm, enabled = canSubmit) {
                if (state.isSubmittingCreate) CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                else Text(stringResource(R.string.carrier_lots_create_submit))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.carrier_lots_create_cancel)) }
        },
    )
}

@Composable
private fun AttachTripDialog(trips: List<Trip>, onSelect: (String) -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.carrier_lots_attach_title)) },
        text = {
            if (trips.isEmpty()) {
                Text(stringResource(R.string.carrier_lots_attach_empty))
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    trips.forEach { trip ->
                        Surface(
                            onClick = { onSelect(trip.id) },
                            shape = MaterialTheme.shapes.small,
                            color = MaterialTheme.colorScheme.surfaceVariant,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text(
                                formatDepartAt(trip.departAt),
                                modifier = Modifier.padding(12.dp),
                                style = MaterialTheme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.carrier_lots_create_cancel)) } },
    )
}

private fun formatQty(qty: Double): String =
    if (qty == qty.toLong().toDouble()) qty.toLong().toString() else "%.2f".format(qty)

/** Mirrors TripsScreen's own formatDepartAt. */
private fun formatDepartAt(iso: String): String = try {
    DateTimeFormatter.ofPattern("d MMM yyyy, HH:mm").withZone(ZoneId.systemDefault()).format(Instant.parse(iso))
} catch (e: Exception) {
    iso
}

private fun LotStatus.tone(): BadgeTone = when (this) {
    LotStatus.ACTIVE -> BadgeTone.POSITIVE
    LotStatus.EXPIRED, LotStatus.WRITTEN_OFF -> BadgeTone.ERROR
    LotStatus.DRAFT -> BadgeTone.NEUTRAL
    else -> BadgeTone.WARNING
}
