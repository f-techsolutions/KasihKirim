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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun BoardScreen(vm: BoardViewModel, isCarrier: Boolean) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Spacer(Modifier.height(12.dp))
            ScreenHeader(stringResource(R.string.board_title))
        }

        if (state.items.isEmpty() && !state.isLoading) {
            item { EmptyStateCard(stringResource(R.string.board_empty)) }
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

    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(kirim.itemDescription, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(kirim.kirimType.labelMs(), tone = if (kirim.kirimType == KirimType.BELI) BadgeTone.INFO else BadgeTone.NEUTRAL)
        }
        Spacer(Modifier.height(6.dp))
        Text(
            "${nodeNames[kirim.originNodeId] ?: "?"} → ${nodeNames[kirim.destNodeId] ?: "?"}",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
        )
        Text(
            "${kirim.estWeightGrams / 1000}kg",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        kirim.deliveryFeeSen?.let {
            Text(
                stringResource(R.string.kirim_quote_delivery, it.format()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        if (isCarrier) {
            if (eligibleTrips.isEmpty()) {
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.board_no_trips), style = MaterialTheme.typography.bodySmall)
            } else {
                Spacer(Modifier.height(10.dp))
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
                Spacer(Modifier.height(10.dp))
                Button(
                    onClick = { selectedTripId?.let(onAccept) },
                    enabled = selectedTripId != null && !isAccepting,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
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

private fun KirimType.labelMs(): String = when (this) {
    KirimType.BELI -> "Beli"
    KirimType.HANTAR -> "Hantar"
    KirimType.PASARAN -> "Pasaran"
}
