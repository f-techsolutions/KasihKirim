package com.ftechsolutions.kasihkirim.ui.orders

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LocalShipping
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
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun OrdersScreen(vm: OrdersViewModel, onOpenDeliveries: () -> Unit) {
    val state by vm.state.collectAsState()

    // See BoardScreen's identical comment: init{}'s one-shot load() doesn't
    // refire when this tab is re-entered without this.
    LaunchedEffect(Unit) { vm.load() }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Spacer(Modifier.height(12.dp))
            ScreenHeader(stringResource(R.string.orders_title))
        }

        item {
            OutlinedButton(
                onClick = onOpenDeliveries,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) {
                Icon(Icons.Filled.LocalShipping, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.deliveries_title))
            }
        }

        if (state.orders.isEmpty() && !state.isLoading && state.error == null) {
            item { EmptyStateCard(stringResource(R.string.orders_empty)) }
        }
        items(state.orders, key = { it.id }) { order -> OrderCard(order, state.nodeNames) }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun OrderCard(order: KirimSummary, nodeNames: Map<String, String>) {
    AppCard {
        Row(horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
            Text(order.itemDescription, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(order.status.labelMs, tone = order.status.tone())
        }
        Spacer(Modifier.height(4.dp))
        Text(
            order.referenceCode,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "${nodeNames[order.originNodeId] ?: "?"} → ${nodeNames[order.destNodeId] ?: "?"}",
            style = MaterialTheme.typography.bodyMedium,
        )
        order.deliveryFeeSen?.let {
            Text(
                stringResource(R.string.kirim_quote_delivery, it.format()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun KirimStatus.tone(): BadgeTone = when {
    this == KirimStatus.DELIVERED || this == KirimStatus.COMPLETED -> BadgeTone.POSITIVE
    isFailure || this == KirimStatus.CANCELLED || this == KirimStatus.EXPIRED -> BadgeTone.ERROR
    this == KirimStatus.DRAFT || this == KirimStatus.POSTED -> BadgeTone.NEUTRAL
    else -> BadgeTone.WARNING
}
