@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.trips

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
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun TripsScreen(vm: TripsViewModel, onOpenVehicles: () -> Unit, onOpenDeliveries: () -> Unit) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.trips_title), style = MaterialTheme.typography.headlineSmall)
        }

        if (state.trips.isEmpty() && !state.isLoading) {
            item { Text(stringResource(R.string.trips_empty)) }
        }
        items(state.trips, key = { it.id }) { trip -> TripCard(trip, state.nodeNames) }

        item {
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = onOpenDeliveries, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.deliveries_title))
            }
            Spacer(Modifier.height(8.dp))
            OutlinedButton(onClick = onOpenVehicles, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.vehicles_title))
            }
        }

        if (state.vehicles.isEmpty() && !state.isLoading) {
            item {
                Spacer(Modifier.height(8.dp))
                Text(stringResource(R.string.trips_no_vehicles), style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            item {
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.trips_new_title), style = MaterialTheme.typography.titleMedium)
            }
            item { TripForm(vm, state.vehicles) }
        }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun TripCard(trip: Trip, nodeNames: Map<String, String>) {
    ElevatedCard {
        Column(Modifier.padding(16.dp)) {
            Text(trip.status.labelMs(), style = MaterialTheme.typography.titleMedium)
            Text(
                "${nodeNames[trip.originNodeId] ?: "?"} → ${nodeNames[trip.destNodeId] ?: "?"}",
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(formatDepartAt(trip.departAt), style = MaterialTheme.typography.bodySmall)
            Text(
                "${trip.reservedWeightGrams / 1000}/${trip.capacityWeightGrams / 1000}kg · " +
                    "${trip.reservedParcels}/${trip.capacityParcels}x",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun TripForm(vm: TripsViewModel, vehicles: List<Vehicle>) {
    val state by vm.state.collectAsState()
    val form = state.form
    var showDatePicker by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
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

        OutlinedTextField(
            value = form.originQuery,
            onValueChange = vm::onOriginQueryChange,
            label = { Text(stringResource(R.string.serviceability_origin)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        if (form.originResults.isNotEmpty() && form.selectedOrigin == null) {
            CommunityResults(form.originResults, onSelect = vm::onOriginSelected)
        }

        OutlinedTextField(
            value = form.destQuery,
            onValueChange = vm::onDestQueryChange,
            label = { Text(stringResource(R.string.serviceability_destination)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        if (form.destResults.isNotEmpty() && form.selectedDest == null) {
            CommunityResults(form.destResults, onSelect = vm::onDestSelected)
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(onClick = { showDatePicker = true }, modifier = Modifier.weight(1f)) {
                Text(
                    form.departDateMillis?.let {
                        Instant.ofEpochMilli(it).atZone(ZoneId.of("UTC")).format(DateTimeFormatter.ofPattern("d MMM"))
                    } ?: stringResource(R.string.trips_pick_date),
                )
            }
            OutlinedButton(onClick = { showTimePicker = true }, modifier = Modifier.weight(1f)) {
                Text("%02d:%02d".format(form.departHour, form.departMinute))
            }
        }

        Button(
            onClick = vm::createTrip,
            enabled = form.canSubmit && !state.isSubmitting,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
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

@Composable
private fun CommunityResults(results: List<Community>, onSelect: (Community) -> Unit) {
    ElevatedCard {
        Column {
            results.forEach { community ->
                TextButton(
                    onClick = { onSelect(community) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("${community.name}, ${community.district}", modifier = Modifier.fillMaxWidth())
                }
            }
        }
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
