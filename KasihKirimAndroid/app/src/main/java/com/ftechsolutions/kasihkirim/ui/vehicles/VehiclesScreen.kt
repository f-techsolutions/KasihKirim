@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.vehicles

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.Vehicle
import com.ftechsolutions.kasihkirim.domain.model.VehicleType
import com.ftechsolutions.kasihkirim.ui.auth.messageRes

@Composable
fun VehiclesScreen(vm: VehiclesViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.vehicles_title)) },
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

            if (state.vehicles.isEmpty() && !state.isLoading) {
                item { Text(stringResource(R.string.vehicles_empty)) }
            }
            items(state.vehicles, key = { it.id }) { vehicle ->
                VehicleCard(
                    vehicle,
                    onEdit = { vm.startEdit(vehicle) },
                    onToggleActive = { vm.setActive(vehicle.id, !vehicle.isActive) },
                )
            }

            item {
                Spacer(Modifier.height(16.dp))
                Text(
                    stringResource(if (state.form.isEditing) R.string.vehicles_edit_title else R.string.vehicles_add_title),
                    style = MaterialTheme.typography.titleMedium,
                )
            }
            item { VehicleForm(vm) }

            state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun VehicleCard(vehicle: Vehicle, onEdit: () -> Unit, onToggleActive: () -> Unit) {
    ElevatedCard {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(vehicle.vehicleType.nameMs, style = MaterialTheme.typography.titleMedium)
                if (!vehicle.isActive) {
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.vehicles_inactive_badge), style = MaterialTheme.typography.labelSmall)
                }
            }
            vehicle.makeModel?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            vehicle.plateNo?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            Text(
                "${vehicle.capacityWeightGrams / 1000}kg · ${vehicle.capacityVolumeCm3}cm³ · ${vehicle.capacityParcels}x",
                style = MaterialTheme.typography.bodySmall,
            )

            Row(Modifier.padding(top = 8.dp)) {
                TextButton(onClick = onEdit) { Text(stringResource(R.string.vehicles_edit)) }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onToggleActive) {
                    Text(stringResource(if (vehicle.isActive) R.string.vehicles_deactivate else R.string.vehicles_activate))
                }
            }
        }
    }
}

@Composable
private fun VehicleForm(vm: VehiclesViewModel) {
    val state by vm.state.collectAsState()
    val form = state.form

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            VehicleType.entries.forEach { type ->
                FilterChip(
                    selected = form.vehicleType == type,
                    onClick = { vm.onVehicleTypeChange(type) },
                    label = { Text(type.nameMs) },
                )
            }
        }

        OutlinedTextField(
            value = form.plateNo,
            onValueChange = vm::onPlateNoChange,
            label = { Text(stringResource(R.string.vehicles_plate_no)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.makeModel,
            onValueChange = vm::onMakeModelChange,
            label = { Text(stringResource(R.string.vehicles_make_model)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.capacityWeightGrams,
            onValueChange = vm::onWeightChange,
            label = { Text(stringResource(R.string.vehicles_capacity_weight)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.capacityVolumeCm3,
            onValueChange = vm::onVolumeChange,
            label = { Text(stringResource(R.string.vehicles_capacity_volume)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.capacityParcels,
            onValueChange = vm::onParcelsChange,
            label = { Text(stringResource(R.string.vehicles_capacity_parcels)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )

        Button(
            onClick = vm::submit,
            enabled = form.canSubmit && !state.isSubmitting,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) {
            if (state.isSubmitting) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(if (form.isEditing) R.string.vehicles_update else R.string.vehicles_save))
            }
        }
        if (form.isEditing) {
            TextButton(onClick = vm::cancelEdit, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.vehicles_cancel_edit))
            }
        }
    }
}
