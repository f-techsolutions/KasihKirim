@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.buy

import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.BuyOrder
import com.ftechsolutions.kasihkirim.domain.model.DeliveryStatusInfo
import com.ftechsolutions.kasihkirim.domain.model.DisputeCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.OrderStatus
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun BuyOrdersScreen(vm: BuyOrdersViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.buy_orders_title)) },
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
            if (state.isLoading && state.orders.isEmpty()) {
                item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
            } else if (state.orders.isEmpty() && state.error == null) {
                item { EmptyStateCard(stringResource(R.string.buy_orders_empty)) }
            }
            items(state.orders, key = { it.id }) { order ->
                BuyOrderCard(order, onClick = { vm.selectOrder(order) })
            }
            state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }

    if (state.selectedOrder != null) {
        BuyOrderDetailSheet(vm)
    }
}

@Composable
private fun BuyOrderCard(order: BuyOrder, onClick: () -> Unit) {
    AppCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
            Text(order.referenceCode, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(order.status.labelMs, tone = order.status.tone())
        }
        Spacer(Modifier.height(4.dp))
        Text(order.totalSen.format(), style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun BuyOrderDetailSheet(vm: BuyOrdersViewModel) {
    val state by vm.state.collectAsState()
    val order = state.selectedOrder ?: return
    val context = LocalContext.current

    LaunchedEffect(state.pendingPaymentUrl) {
        val url = state.pendingPaymentUrl ?: return@LaunchedEffect
        CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
        vm.onPaymentUrlLaunched()
    }

    ModalBottomSheet(onDismissRequest = vm::dismissOrderDetail) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ScreenHeader(stringResource(R.string.buy_order_detail), subtitle = order.referenceCode)
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                StatusBadge(order.status.labelMs, tone = order.status.tone())
                Text(order.totalSen.format(), style = MaterialTheme.typography.titleMedium)
            }

            AppCard {
                order.items.forEach { item ->
                    Row(modifier = Modifier.fillMaxWidth()) {
                        Text(
                            "${item.quantity}x ${item.titleSnapshot}",
                            style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.weight(1f),
                        )
                        Text(item.lineTotalSen.format(), style = MaterialTheme.typography.bodyMedium)
                    }
                }
                HorizontalDivider(Modifier.padding(vertical = 6.dp), color = MaterialTheme.colorScheme.outlineVariant)
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.buy_order_goods_subtotal), style = MaterialTheme.typography.bodySmall)
                    Text(order.goodsSubtotalSen.format(), style = MaterialTheme.typography.bodySmall)
                }
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.buy_order_delivery_fee), style = MaterialTheme.typography.bodySmall)
                    Text(order.deliveryFeeSen.format(), style = MaterialTheme.typography.bodySmall)
                }
            }

            if (order.paymentMethod != null && order.paymentMethod != "COD") {
                PaymentStatusRow(vm, order)
            }

            DeliveryStatusSection(state.deliveryStatus, state.isLoadingDeliveryStatus)

            if (state.showDisputeForm) {
                DisputeForm(vm)
            } else if (state.disputeSubmitted) {
                Text(stringResource(R.string.buy_dispute_submitted), color = MaterialTheme.colorScheme.primary)
            } else {
                OutlinedButton(
                    onClick = vm::openDisputeForm,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
                ) { Text(stringResource(R.string.buy_order_report_problem)) }
            }

            state.error?.let { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }

            Button(
                onClick = vm::dismissOrderDetail,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
            ) { Text(stringResource(R.string.buy_close)) }
        }
    }
}

/** Found missing in review: the buyer had a status badge and (for non-COD) a
 *  payment poll, but no visibility into pickup/transit/delivery progress at
 *  all. null means the order has no kirim yet -- e.g. a prepaid order still
 *  awaiting payment, never bridged -- a normal state, not an error, so this
 *  renders a plain hint rather than an error card. */
@Composable
private fun DeliveryStatusSection(status: DeliveryStatusInfo?, isLoading: Boolean) {
    AppCard {
        Text(stringResource(R.string.buy_delivery_status_title), style = MaterialTheme.typography.titleSmall)
        Spacer(Modifier.height(6.dp))
        when {
            isLoading && status == null -> Box(Modifier.fillMaxWidth().padding(8.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            }
            status == null -> Text(
                stringResource(R.string.buy_delivery_not_bridged),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            else -> {
                StatusBadge(status.kirimStatus.labelMs, tone = status.kirimStatus.tone())
                Spacer(Modifier.height(6.dp))
                StatusBadge(
                    stringResource(
                        if (status.carrierAssigned) R.string.buy_delivery_carrier_assigned
                        else R.string.buy_delivery_carrier_not_assigned,
                    ),
                    tone = if (status.carrierAssigned) BadgeTone.POSITIVE else BadgeTone.NEUTRAL,
                )
            }
        }
    }
}

private fun KirimStatus.tone(): BadgeTone = when {
    this == KirimStatus.DELIVERED || this == KirimStatus.COMPLETED -> BadgeTone.POSITIVE
    isFailure || this == KirimStatus.CANCELLED || this == KirimStatus.EXPIRED -> BadgeTone.ERROR
    this == KirimStatus.DRAFT || this == KirimStatus.POSTED -> BadgeTone.NEUTRAL
    else -> BadgeTone.WARNING
}

@Composable
private fun PaymentStatusRow(vm: BuyOrdersViewModel, order: BuyOrder) {
    val state by vm.state.collectAsState()
    val status = state.paymentStatus

    AppCard {
        when (status?.status) {
            "SUCCEEDED", "CAPTURED" ->
                Text(stringResource(R.string.buy_payment_succeeded), color = MaterialTheme.colorScheme.primary)
            "FAILED", "CANCELLED", "EXPIRED" ->
                Text(stringResource(R.string.buy_payment_failed), color = MaterialTheme.colorScheme.error)
            else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(
                    onClick = { vm.payNow(order.id) },
                    enabled = !state.isPreparingPayment,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
                ) {
                    if (state.isPreparingPayment) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.buy_payment_pay_now))
                    }
                }
                TextButton(onClick = { vm.refreshPaymentStatus(order.id) }) {
                    Text(stringResource(R.string.buy_payment_refresh_status))
                }
            }
        }
    }
}

@Composable
private fun DisputeForm(vm: BuyOrdersViewModel) {
    val state by vm.state.collectAsState()

    AppCard {
        Text(stringResource(R.string.buy_dispute_title), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.buy_dispute_category), style = MaterialTheme.typography.labelLarge)
        Spacer(Modifier.height(4.dp))
        FlowRowChips(state.disputeCategory, vm::onDisputeCategorySelected)
        Spacer(Modifier.height(8.dp))
        OutlinedTextField(
            value = state.disputeDescription,
            onValueChange = vm::onDisputeDescriptionChange,
            label = { Text(stringResource(R.string.buy_dispute_description)) },
            minLines = 3,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(Modifier.height(8.dp))
        Button(
            onClick = vm::submitDispute,
            enabled = !state.isFilingDispute && state.disputeDescription.trim().length >= 10,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
        ) {
            if (state.isFilingDispute) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(R.string.buy_dispute_submit))
            }
        }
    }
}

@Composable
private fun FlowRowChips(selected: DisputeCategory, onSelect: (DisputeCategory) -> Unit) {
    // A plain wrapping Row would clip on narrow screens; two short rows read
    // fine for eight short labels and needs no extra layout dependency.
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

private fun OrderStatus.tone(): BadgeTone = when (this) {
    OrderStatus.SETTLED, OrderStatus.FULFILLED, OrderStatus.PAID -> BadgeTone.POSITIVE
    OrderStatus.PAYMENT_FAILED, OrderStatus.EXPIRED, OrderStatus.REJECTED_BY_SELLER, OrderStatus.CANCELLED -> BadgeTone.ERROR
    OrderStatus.CREATED -> BadgeTone.NEUTRAL
    else -> BadgeTone.WARNING
}
