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
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun VehiclesScreen(vm: VehiclesViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.vehicles_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }

            if (state.vehicles.isEmpty() && !state.isLoading && state.error == null) {
                item { EmptyStateCard(stringResource(R.string.vehicles_empty)) }
            }
            items(state.vehicles, key = { it.id }) { vehicle ->
                VehicleCard(
                    vehicle,
                    onEdit = { vm.startEdit(vehicle) },
                    onToggleActive = { vm.setActive(vehicle.id, !vehicle.isActive) },
                )
            }

            item {
                Spacer(Modifier.height(4.dp))
                ScreenHeader(
                    stringResource(if (state.form.isEditing) R.string.vehicles_edit_title else R.string.vehicles_add_title),
                )
            }
            item { AppCard { VehicleForm(vm) } }

            state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun VehicleCard(vehicle: Vehicle, onEdit: () -> Unit, onToggleActive: () -> Unit) {
    AppCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(vehicle.vehicleType.nameMs, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            if (!vehicle.isActive) {
                StatusBadge(stringResource(R.string.vehicles_inactive_badge), tone = BadgeTone.NEUTRAL)
            }
        }
        vehicle.makeModel?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        vehicle.plateNo?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Spacer(Modifier.height(2.dp))
        Text(
            "${vehicle.capacityWeightGrams / 1000}kg · ${vehicle.capacityVolumeCm3}cm³ · ${vehicle.capacityParcels}x",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        HorizontalDivider(Modifier.padding(top = 12.dp, bottom = 8.dp), color = MaterialTheme.colorScheme.outlineVariant)
        Row {
            TextButton(onClick = onEdit, contentPadding = PaddingValues(horizontal = 4.dp)) {
                Text(stringResource(R.string.vehicles_edit))
            }
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onToggleActive, contentPadding = PaddingValues(horizontal = 4.dp)) {
                Text(stringResource(if (vehicle.isActive) R.string.vehicles_deactivate else R.string.vehicles_activate))
            }
        }
    }
}

@Composable
private fun VehicleForm(vm: VehiclesViewModel) {
    val state by vm.state.collectAsState()
    val form = state.form

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
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
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.makeModel,
            onValueChange = vm::onMakeModelChange,
            label = { Text(stringResource(R.string.vehicles_make_model)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.capacityWeightGrams,
            onValueChange = vm::onWeightChange,
            label = { Text(stringResource(R.string.vehicles_capacity_weight)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.capacityVolumeCm3,
            onValueChange = vm::onVolumeChange,
            label = { Text(stringResource(R.string.vehicles_capacity_volume)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.capacityParcels,
            onValueChange = vm::onParcelsChange,
            label = { Text(stringResource(R.string.vehicles_capacity_parcels)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )

        Button(
            onClick = vm::submit,
            enabled = form.canSubmit && !state.isSubmitting,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
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
