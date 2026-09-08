package com.ftechsolutions.kasihkirim.ui.orders

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.ui.auth.messageRes

@Composable
fun OrdersScreen(vm: OrdersViewModel, onOpenDeliveries: () -> Unit) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.orders_title), style = MaterialTheme.typography.headlineSmall)
        }

        item {
            OutlinedButton(onClick = onOpenDeliveries, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.deliveries_title))
            }
        }

        if (state.orders.isEmpty() && !state.isLoading) {
            item { Text(stringResource(R.string.orders_empty)) }
        }
        items(state.orders, key = { it.id }) { order -> OrderCard(order, state.nodeNames) }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun OrderCard(order: KirimSummary, nodeNames: Map<String, String>) {
    ElevatedCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Text(order.itemDescription, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                Text(order.status.labelMs, style = MaterialTheme.typography.labelLarge)
            }
            Text(order.referenceCode, style = MaterialTheme.typography.labelSmall)
            Text(
                "${nodeNames[order.originNodeId] ?: "?"} → ${nodeNames[order.destNodeId] ?: "?"}",
                style = MaterialTheme.typography.bodyMedium,
            )
            order.deliveryFeeSen?.let { Text(stringResource(R.string.kirim_quote_delivery, it.format())) }
        }
    }
}
