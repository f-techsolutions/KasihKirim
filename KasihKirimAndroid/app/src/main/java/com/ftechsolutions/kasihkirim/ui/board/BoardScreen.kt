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
import com.ftechsolutions.kasihkirim.domain.model.CapacityInvite
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

        if (state.invites.isNotEmpty()) {
            item { ScreenHeader(stringResource(R.string.board_invites_title)) }
            items(state.invites, key = { it.id }) { invite ->
                InviteCard(
                    invite = invite,
                    nodeNames = state.nodeNames,
                    hasResponded = invite.id in state.respondedInviteIds,
                    onRespond = { vm.respondToInvite(invite.id) },
                )
            }
            item { Spacer(Modifier.height(4.dp)) }
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
        // A PASARAN listing's real cash-handling commitment: rpc_accept_offer
        // charges the whole order (goods + carriage) as COD the instant this
        // carrier accepts, not just the delivery_fee_sen shown above.
        kirim.codTotalSen?.let {
            Spacer(Modifier.height(2.dp))
            Text(
                stringResource(R.string.board_cod_total, it.format()),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
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

@Composable
private fun InviteCard(
    invite: CapacityInvite,
    nodeNames: Map<String, String>,
    hasResponded: Boolean,
    onRespond: () -> Unit,
) {
    AppCard {
        Text(
            "${nodeNames[invite.originNodeId] ?: "?"} → ${nodeNames[invite.destNodeId] ?: "?"}",
            style = MaterialTheme.typography.titleMedium,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            invite.message ?: stringResource(R.string.board_invite_default_message),
            style = MaterialTheme.typography.bodyMedium,
        )
        Spacer(Modifier.height(10.dp))
        if (hasResponded) {
            Text(
                stringResource(R.string.board_invite_responded),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary,
            )
        } else {
            OutlinedButton(onClick = onRespond, shape = MaterialTheme.shapes.small, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.board_invite_respond))
            }
        }
    }
}

private fun KirimType.labelMs(): String = when (this) {
    KirimType.BELI -> "Beli"
    KirimType.HANTAR -> "Hantar"
    KirimType.PASARAN -> "Pasaran"
}
