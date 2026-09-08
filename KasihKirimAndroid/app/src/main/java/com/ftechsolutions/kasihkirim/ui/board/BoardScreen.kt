package com.ftechsolutions.kasihkirim.ui.board

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.ui.auth.messageRes

@Composable
fun BoardScreen(vm: BoardViewModel, isCarrier: Boolean) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.board_title), style = MaterialTheme.typography.headlineSmall)
        }

        if (state.items.isEmpty() && !state.isLoading) {
            item { Text(stringResource(R.string.board_empty)) }
        }
        items(state.items, key = { it.id }) { kirim ->
            BoardCard(
                kirim = kirim,
                nodeNames = state.nodeNames,
                isCarrier = isCarrier,
                eligibleTrips = state.eligibleTrips,
                isAccepting = state.acceptingKirimId == kirim.id,
                onAccept = { tripId -> vm.acceptOffer(kirim.id, tripId) },
            )
        }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun BoardCard(
    kirim: KirimSummary,
    nodeNames: Map<String, String>,
    isCarrier: Boolean,
    eligibleTrips: List<Trip>,
    isAccepting: Boolean,
    onAccept: (tripId: String) -> Unit,
) {
    var selectedTripId by remember(kirim.id) { mutableStateOf<String?>(null) }

    ElevatedCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(kirim.itemDescription, style = MaterialTheme.typography.titleMedium)
            Text(
                "${nodeNames[kirim.originNodeId] ?: "?"} → ${nodeNames[kirim.destNodeId] ?: "?"}",
                style = MaterialTheme.typography.bodyMedium,
            )
            Text("${kirim.estWeightGrams / 1000}kg · ${kirim.kirimType.labelMs()}", style = MaterialTheme.typography.bodySmall)
            kirim.deliveryFeeSen?.let { Text(stringResource(R.string.kirim_quote_delivery, it.format())) }

            if (isCarrier) {
                if (eligibleTrips.isEmpty()) {
                    Text(stringResource(R.string.board_no_trips), style = MaterialTheme.typography.bodySmall)
                } else {
                    Spacer(Modifier.height(4.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        eligibleTrips.forEach { trip ->
                            FilterChip(
                                selected = selectedTripId == trip.id,
                                onClick = { selectedTripId = trip.id },
                                label = { Text("${nodeNames[trip.originNodeId] ?: "?"} → ${nodeNames[trip.destNodeId] ?: "?"}") },
                            )
                        }
                    }
                    Button(
                        onClick = { selectedTripId?.let(onAccept) },
                        enabled = selectedTripId != null && !isAccepting,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                    ) {
                        if (isAccepting) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.board_accept))
                        }
                    }
                }
            }
        }
    }
}

private fun KirimType.labelMs(): String = when (this) {
    KirimType.BELI -> "Beli"
    KirimType.HANTAR -> "Hantar"
    KirimType.PASARAN -> "Pasaran"
}
