@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.deliveries

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
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.NON_PROOF_DELIVERY_TRANSITIONS
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.ui.auth.messageRes

@Composable
fun DeliveriesScreen(vm: DeliveriesViewModel, roles: Set<UserRole>, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.deliveries_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { Spacer(Modifier.height(8.dp)) }

            if (state.deliveries.isEmpty() && !state.isLoading) {
                item { Text(stringResource(R.string.deliveries_empty)) }
            }
            items(state.deliveries, key = { it.id }) { delivery ->
                DeliveryCard(
                    delivery = delivery,
                    roles = roles,
                    isTransitioning = state.transitioningId == delivery.id,
                    onEvent = { event -> vm.transition(delivery.id, event) },
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

    ElevatedCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(delivery.itemDescription, style = MaterialTheme.typography.titleMedium)
            Text(delivery.referenceCode, style = MaterialTheme.typography.labelSmall)
            Text(delivery.status.labelMs, style = MaterialTheme.typography.bodyMedium)
            delivery.carrierEarningSen?.let { Text(stringResource(R.string.deliveries_carrier_earning, it.format())) }
            delivery.failureReason?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }

            if (availableEvents.isNotEmpty()) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    availableEvents.forEach { rule ->
                        OutlinedButton(
                            onClick = { onEvent(rule.event) },
                            enabled = !isTransitioning,
                        ) {
                            if (isTransitioning) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                            } else {
                                Text(rule.event.labelMs())
                            }
                        }
                    }
                }
            }
        }
    }
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
