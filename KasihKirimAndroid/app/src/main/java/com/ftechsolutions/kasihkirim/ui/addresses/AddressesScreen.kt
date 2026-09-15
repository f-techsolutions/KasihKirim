@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.addresses

import androidx.compose.foundation.BorderStroke
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
import com.ftechsolutions.kasihkirim.ui.common.CommunityPicker
import com.ftechsolutions.kasihkirim.ui.common.InlineNotice
import com.ftechsolutions.kasihkirim.ui.common.NoticeTone

@Composable
fun AddressesScreen(vm: AddressesViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.addresses_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                ),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }

            if (state.addresses.isEmpty() && !state.isLoading && state.error == null) {
                item { EmptyAddressesCard() }
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
                Spacer(Modifier.height(8.dp))
                SectionHeading(
                    stringResource(if (state.form.isEditing) R.string.addresses_edit_title else R.string.addresses_add_title),
                )
            }
            item { AddressFormCard(vm) }

            state.error?.let {
                item {
                    InlineNotice(
                        text = stringResource(R.string.err_unexpected),
                        tone = NoticeTone.ERROR,
                    )
                }
            }
            item { Spacer(Modifier.height(24.dp)) }
        }
    }
}

@Composable
private fun SectionHeading(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onBackground,
    )
}

@Composable
private fun EmptyAddressesCard() {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(20.dp)) {
            Text(
                stringResource(R.string.addresses_empty),
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.addresses_add_title) + " ↓",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun AddressCard(address: Address, onSetDefault: () -> Unit, onDelete: () -> Unit, onEdit: () -> Unit) {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 1.dp,
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    address.label,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (address.isDefault) {
                    Spacer(Modifier.width(8.dp))
                    Pill(stringResource(R.string.addresses_default_badge))
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                "${address.recipientName} · ${address.recipientPhone}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(2.dp))
            Text(
                "${address.community.name}, ${address.community.district}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                address.landmarkNote,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            HorizontalDivider(
                Modifier.padding(top = 14.dp, bottom = 10.dp),
                color = MaterialTheme.colorScheme.outlineVariant,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!address.isDefault) {
                    TextButton(onClick = onSetDefault, contentPadding = PaddingValues(horizontal = 4.dp)) {
                        Text(stringResource(R.string.addresses_set_default))
                    }
                    Spacer(Modifier.width(4.dp))
                }
                TextButton(onClick = onEdit, contentPadding = PaddingValues(horizontal = 4.dp)) {
                    Text(stringResource(R.string.addresses_edit))
                }
                Spacer(Modifier.weight(1f))
                TextButton(
                    onClick = onDelete,
                    contentPadding = PaddingValues(horizontal = 4.dp),
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.error),
                ) { Text(stringResource(R.string.addresses_delete)) }
            }
        }
    }
}

@Composable
private fun Pill(text: String) {
    Surface(
        shape = MaterialTheme.shapes.extraLarge,
        color = MaterialTheme.colorScheme.tertiaryContainer,
    ) {
        Text(
            text,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onTertiaryContainer,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
        )
    }
}

@Composable
private fun AddressFormCard(vm: AddressesViewModel) {
    val state by vm.state.collectAsState()
    val form = state.form

    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.surface,
        shadowElevation = 1.dp,
        tonalElevation = 1.dp,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            OutlinedTextField(
                value = form.label,
                onValueChange = vm::onLabelChange,
                label = { Text(stringResource(R.string.addresses_label)) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = form.recipientName,
                onValueChange = vm::onRecipientNameChange,
                label = { Text(stringResource(R.string.addresses_recipient_name)) },
                singleLine = true,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = form.recipientPhone,
                onValueChange = vm::onRecipientPhoneChange,
                label = { Text(stringResource(R.string.addresses_recipient_phone)) },
                placeholder = { Text("+60123456789") },
                singleLine = true,
                isError = form.phoneInvalid,
                supportingText = {
                    Text(
                        if (form.phoneInvalid) {
                            stringResource(R.string.addresses_phone_format_error)
                        } else {
                            stringResource(R.string.addresses_phone_format_hint)
                        },
                    )
                },
                shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                modifier = Modifier.fillMaxWidth(),
            )

            CommunityPicker(
                label = stringResource(R.string.addresses_community),
                hint = stringResource(R.string.picker_search_hint),
                changeLabel = stringResource(R.string.picker_change),
                notSelectedHint = stringResource(R.string.picker_not_selected),
                query = form.communityQuery,
                selected = form.selectedCommunity,
                results = form.communityResults,
                onQueryChange = vm::onCommunityQueryChange,
                onSelect = vm::onCommunitySelected,
                onClear = vm::onCommunityCleared,
            )

            OutlinedTextField(
                value = form.landmarkNote,
                onValueChange = vm::onLandmarkNoteChange,
                label = { Text(stringResource(R.string.addresses_landmark)) },
                minLines = 2,
                shape = MaterialTheme.shapes.small,
                modifier = Modifier.fillMaxWidth(),
            )

            Button(
                onClick = vm::submit,
                enabled = form.canSubmit && !state.isSubmitting,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
            ) {
                if (state.isSubmitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(20.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                } else {
                    Text(
                        stringResource(if (form.isEditing) R.string.addresses_update else R.string.addresses_save),
                        style = MaterialTheme.typography.labelLarge,
                    )
                }
            }
            if (form.isEditing) {
                TextButton(onClick = vm::cancelEdit, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.addresses_cancel_edit))
                }
            }
        }
    }
}

