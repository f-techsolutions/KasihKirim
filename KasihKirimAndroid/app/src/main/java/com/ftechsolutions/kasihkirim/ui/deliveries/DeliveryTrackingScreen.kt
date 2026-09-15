@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.deliveries

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.DeliveryLocation
import com.ftechsolutions.kasihkirim.domain.model.TrackingWaypoint
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** Reachable from a delivery card in the trackable window
 *  (TRACKABLE_DELIVERY_STATUSES) for whoever the delivery already belongs to
 *  -- deliveries_select's own RLS (and rpc_get_delivery_tracking's mirror of
 *  it) is what actually decides whether this call succeeds, this screen
 *  makes no separate role check.
 *
 *  No Maps SDK is used -- that needs a billed API key this app doesn't
 *  provision. Instead: the carrier's raw position plus an "open in the
 *  device's own Maps app" action (a plain geo: intent, no key required). */
@Composable
fun DeliveryTrackingScreen(vm: DeliveryTrackingViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()
    val context = LocalContext.current

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.tracking_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Spacer(Modifier.height(4.dp))

            if (state.isLoading) {
                Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            }

            state.tracking?.let { tracking ->
                AppCard {
                    Text(tracking.deliveryStatus.labelMs, style = MaterialTheme.typography.titleMedium)
                    tracking.origin?.let { WaypointRow(R.string.tracking_origin, it) }
                    tracking.destination?.let { WaypointRow(R.string.tracking_destination, it) }
                }

                val location = tracking.carrierLocation
                if (location != null) {
                    CarrierLocationCard(location, onOpenMaps = {
                        val uri = Uri.parse("geo:${location.lat},${location.lng}?q=${location.lat},${location.lng}")
                        context.startActivity(Intent(Intent.ACTION_VIEW, uri))
                    })
                } else if (!state.isLoading) {
                    EmptyStateCard(stringResource(R.string.tracking_no_location_yet))
                }
            }

            state.error?.let { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun WaypointRow(labelRes: Int, waypoint: TrackingWaypoint) {
    Spacer(Modifier.height(4.dp))
    Text(
        stringResource(labelRes, waypoint.name),
        style = MaterialTheme.typography.bodyMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun CarrierLocationCard(location: DeliveryLocation, onOpenMaps: () -> Unit) {
    AppCard {
        Text(stringResource(R.string.tracking_carrier_position), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(4.dp))
        Text(
            "${"%.5f".format(location.lat)}, ${"%.5f".format(location.lng)}",
            style = MaterialTheme.typography.bodyMedium,
        )
        location.speedKmh?.let {
            Spacer(Modifier.height(2.dp))
            Text(stringResource(R.string.tracking_speed, it), style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(2.dp))
        Text(
            stringResource(R.string.tracking_updated_at, formatRecordedAt(location.recordedAt)),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(10.dp))
        Button(onClick = onOpenMaps, shape = MaterialTheme.shapes.small) {
            Text(stringResource(R.string.tracking_open_maps))
        }
    }
}

/** Mirrors TripsScreen's own formatDepartAt -- same ISO-instant-to-local-time
 *  pattern already used for a trip's departure time. */
private fun formatRecordedAt(iso: String): String = try {
    DateTimeFormatter.ofPattern("d MMM, HH:mm").withZone(ZoneId.systemDefault()).format(Instant.parse(iso))
} catch (e: Exception) {
    iso
}
