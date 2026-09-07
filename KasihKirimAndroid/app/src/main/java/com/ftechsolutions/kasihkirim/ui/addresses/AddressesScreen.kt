@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.addresses

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
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
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.Community

@Composable
fun AddressesScreen(vm: AddressesViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.addresses_title)) },
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

            if (state.addresses.isEmpty() && !state.isLoading) {
                item { Text(stringResource(R.string.addresses_empty)) }
            }
            items(state.addresses, key = { it.id }) { address ->
                AddressCard(
                    address,
                    onSetDefault = { vm.setDefault(address.id) },
                    onDelete = { vm.delete(address.id) },
                    onEdit = { vm.startEdit(address) },
                )
            }

            item {
                Spacer(Modifier.height(16.dp))
                Text(
                    stringResource(if (state.form.isEditing) R.string.addresses_edit_title else R.string.addresses_add_title),
                    style = MaterialTheme.typography.titleMedium,
                )
            }
            item { AddressForm(vm) }

            state.error?.let { item { Text(stringResource(R.string.err_unexpected), color = MaterialTheme.colorScheme.error) } }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun AddressCard(address: Address, onSetDefault: () -> Unit, onDelete: () -> Unit, onEdit: () -> Unit) {
    ElevatedCard {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(address.label, style = MaterialTheme.typography.titleMedium)
                if (address.isDefault) {
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.addresses_default_badge), style = MaterialTheme.typography.labelSmall)
                }
            }
            Text(address.recipientName, style = MaterialTheme.typography.bodyMedium)
            Text(address.recipientPhone, style = MaterialTheme.typography.bodyMedium)
            Text(
                "${address.community.name}, ${address.community.district}",
                style = MaterialTheme.typography.bodySmall,
            )
            Text(address.landmarkNote, style = MaterialTheme.typography.bodySmall)

            Row(Modifier.padding(top = 8.dp)) {
                if (!address.isDefault) {
                    TextButton(onClick = onSetDefault) { Text(stringResource(R.string.addresses_set_default)) }
                }
                TextButton(onClick = onEdit) { Text(stringResource(R.string.addresses_edit)) }
                Spacer(Modifier.weight(1f))
                TextButton(onClick = onDelete) { Text(stringResource(R.string.addresses_delete)) }
            }
        }
    }
}

@Composable
private fun AddressForm(vm: AddressesViewModel) {
    val state by vm.state.collectAsState()
    val form = state.form

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            value = form.label,
            onValueChange = vm::onLabelChange,
            label = { Text(stringResource(R.string.addresses_label)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.recipientName,
            onValueChange = vm::onRecipientNameChange,
            label = { Text(stringResource(R.string.addresses_recipient_name)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.recipientPhone,
            onValueChange = vm::onRecipientPhoneChange,
            label = { Text(stringResource(R.string.addresses_recipient_phone)) },
            placeholder = { Text("+60123456789") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
            modifier = Modifier.fillMaxWidth(),
        )

        OutlinedTextField(
            value = form.communityQuery,
            onValueChange = vm::onCommunityQueryChange,
            label = { Text(stringResource(R.string.addresses_community)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        if (form.communityResults.isNotEmpty() && form.selectedCommunity == null) {
            CommunityResults(form.communityResults, onSelect = vm::onCommunitySelected)
        }

        OutlinedTextField(
            value = form.landmarkNote,
            onValueChange = vm::onLandmarkNoteChange,
            label = { Text(stringResource(R.string.addresses_landmark)) },
            minLines = 2,
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
                Text(stringResource(if (form.isEditing) R.string.addresses_update else R.string.addresses_save))
            }
        }
        if (form.isEditing) {
            TextButton(onClick = vm::cancelEdit, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.addresses_cancel_edit))
            }
        }
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
