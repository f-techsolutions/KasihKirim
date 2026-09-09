@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.trips

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.LocalShipping
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
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.CommunityPicker
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun TripsScreen(vm: TripsViewModel, onOpenVehicles: () -> Unit, onOpenDeliveries: () -> Unit) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Spacer(Modifier.height(12.dp))
            ScreenHeader(stringResource(R.string.trips_title))
        }

        if (state.trips.isEmpty() && !state.isLoading) {
            item { EmptyStateCard(stringResource(R.string.trips_empty)) }
        }
        items(state.trips, key = { it.id }) { trip -> TripCard(trip, state.nodeNames) }

        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedButton(onClick = onOpenDeliveries, shape = MaterialTheme.shapes.medium, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.LocalShipping, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.deliveries_title))
                }
                OutlinedButton(onClick = onOpenVehicles, shape = MaterialTheme.shapes.medium, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Filled.DirectionsCar, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.vehicles_title))
                }
            }
        }

        if (state.vehicles.isEmpty() && !state.isLoading) {
            item { EmptyStateCard(stringResource(R.string.trips_no_vehicles)) }
        } else {
            item {
                Spacer(Modifier.height(4.dp))
                ScreenHeader(stringResource(R.string.trips_new_title))
            }
            item { AppCard { TripForm(vm, state.vehicles) } }
        }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun TripCard(trip: Trip, nodeNames: Map<String, String>) {
    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(
                "${nodeNames[trip.originNodeId] ?: "?"} → ${nodeNames[trip.destNodeId] ?: "?"}",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.weight(1f),
            )
            StatusBadge(trip.status.labelMs(), tone = trip.status.tone())
        }
        Spacer(Modifier.height(4.dp))
        Text(
            formatDepartAt(trip.departAt),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(2.dp))
        Text(
            "${trip.reservedWeightGrams / 1000}/${trip.capacityWeightGrams / 1000}kg · " +
                "${trip.reservedParcels}/${trip.capacityParcels}x",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun TripForm(vm: TripsViewModel, vehicles: List<Vehicle>) {
    val state by vm.state.collectAsState()
    val form = state.form
    var showDatePicker by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(stringResource(R.string.trips_vehicle), style = MaterialTheme.typography.labelLarge)
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            vehicles.forEach { vehicle ->
                FilterChip(
                    selected = form.selectedVehicle?.id == vehicle.id,
                    onClick = { vm.onVehicleSelected(vehicle) },
                    label = { Text(vehicle.plateNo ?: vehicle.vehicleType.nameMs) },
                )
            }
        }

        CommunityPicker(
            label = stringResource(R.string.serviceability_origin),
            hint = stringResource(R.string.picker_search_hint),
            changeLabel = stringResource(R.string.picker_change),
            notSelectedHint = stringResource(R.string.picker_not_selected),
            query = form.originQuery,
            selected = form.selectedOrigin,
            results = form.originResults,
            onQueryChange = vm::onOriginQueryChange,
            onSelect = vm::onOriginSelected,
            onClear = vm::onOriginCleared,
        )

        CommunityPicker(
            label = stringResource(R.string.serviceability_destination),
            hint = stringResource(R.string.picker_search_hint),
            changeLabel = stringResource(R.string.picker_change),
            notSelectedHint = stringResource(R.string.picker_not_selected),
            query = form.destQuery,
            selected = form.selectedDest,
            results = form.destResults,
            onQueryChange = vm::onDestQueryChange,
            onSelect = vm::onDestSelected,
            onClear = vm::onDestCleared,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { showDatePicker = true }, shape = MaterialTheme.shapes.small, modifier = Modifier.weight(1f)) {
                Text(
                    form.departDateMillis?.let {
                        Instant.ofEpochMilli(it).atZone(ZoneId.of("UTC")).format(DateTimeFormatter.ofPattern("d MMM"))
                    } ?: stringResource(R.string.trips_pick_date),
                )
            }
            OutlinedButton(onClick = { showTimePicker = true }, shape = MaterialTheme.shapes.small, modifier = Modifier.weight(1f)) {
                Text("%02d:%02d".format(form.departHour, form.departMinute))
            }
        }

        Button(
            onClick = vm::createTrip,
            enabled = form.canSubmit && !state.isSubmitting,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) {
            if (state.isSubmitting) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(R.string.trips_create))
            }
        }
    }

    if (showDatePicker) {
        val datePickerState = rememberDatePickerState(initialSelectedDateMillis = form.departDateMillis)
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    vm.onDepartDateChange(datePickerState.selectedDateMillis)
                    showDatePicker = false
                }) { Text(stringResource(android.R.string.ok)) }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text(stringResource(android.R.string.cancel)) }
            },
        ) { DatePicker(state = datePickerState) }
    }

    if (showTimePicker) {
        val timePickerState = rememberTimePickerState(initialHour = form.departHour, initialMinute = form.departMinute)
        AlertDialog(
            onDismissRequest = { showTimePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    vm.onDepartTimeChange(timePickerState.hour, timePickerState.minute)
                    showTimePicker = false
                }) { Text(stringResource(android.R.string.ok)) }
            },
            dismissButton = {
                TextButton(onClick = { showTimePicker = false }) { Text(stringResource(android.R.string.cancel)) }
            },
            text = { TimePicker(state = timePickerState) },
        )
    }
}

private fun formatDepartAt(iso: String): String = try {
    DateTimeFormatter.ofPattern("d MMM yyyy, HH:mm").withZone(ZoneId.systemDefault()).format(Instant.parse(iso))
} catch (e: Exception) {
    iso
}

private fun TripStatus.labelMs(): String = when (this) {
    TripStatus.DRAFT -> "Draf"
    TripStatus.ANNOUNCED -> "Diumumkan"
    TripStatus.BOARDING -> "Sedang Mengisi"
    TripStatus.DEPARTED -> "Berlepas"
    TripStatus.IN_PROGRESS -> "Dalam Perjalanan"
    TripStatus.ARRIVED -> "Sampai"
    TripStatus.CLOSED -> "Selesai"
    TripStatus.CANCELLED -> "Dibatalkan"
}

private fun TripStatus.tone(): BadgeTone = when (this) {
    TripStatus.DRAFT -> BadgeTone.NEUTRAL
    TripStatus.ANNOUNCED, TripStatus.BOARDING -> BadgeTone.INFO
    TripStatus.DEPARTED, TripStatus.IN_PROGRESS -> BadgeTone.WARNING
    TripStatus.ARRIVED, TripStatus.CLOSED -> BadgeTone.POSITIVE
    TripStatus.CANCELLED -> BadgeTone.ERROR
}
