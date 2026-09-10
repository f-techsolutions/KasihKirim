@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.send

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
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
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimCreated
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.CommunityPicker
import com.ftechsolutions.kasihkirim.ui.common.GradientHeroCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader

@Composable
fun SendScreen(vm: KirimQuoteViewModel) {
    val state by vm.state.collectAsState()

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Spacer(Modifier.height(12.dp))
        ScreenHeader(stringResource(R.string.kirim_title))

        val created = state.created
        if (created != null) {
            KirimCreatedResult(created)
        } else {
            KirimForm(vm, state)
        }

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun KirimForm(vm: KirimQuoteViewModel, state: KirimUiState) {
    val form = state.form

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        AppCard {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                KirimType.entries.filter { it != KirimType.PASARAN }.forEach { type ->
                    FilterChip(
                        selected = form.kirimType == type,
                        onClick = { vm.onKirimTypeChange(type) },
                        label = { Text(stringResource(if (type == KirimType.BELI) R.string.kirim_type_beli else R.string.kirim_type_hantar)) },
                    )
                }
            }

            Spacer(Modifier.height(14.dp))
            Text(stringResource(R.string.kirim_category), style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.height(6.dp))
            FlowOfChips {
                KirimCategory.entries.forEach { category ->
                    FilterChip(
                        selected = form.category == category,
                        onClick = { vm.onCategorySelected(category) },
                        label = { Text(category.nameMs) },
                    )
                }
            }

            Spacer(Modifier.height(14.dp))
            val weightInvalid = form.weightGrams.isNotEmpty() && !form.weightValid
            OutlinedTextField(
                value = form.weightGrams,
                onValueChange = vm::onWeightChange,
                label = { Text(stringResource(R.string.kirim_weight)) },
                singleLine = true,
                isError = weightInvalid,
                supportingText = {
                    Text(
                        if (weightInvalid) {
                            stringResource(R.string.kirim_weight_error)
                        } else {
                            stringResource(R.string.kirim_weight_hint)
                        },
                    )
                },
                shape = MaterialTheme.shapes.small,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                modifier = Modifier.fillMaxWidth(),
            )

            if (form.kirimType == KirimType.BELI) {
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = form.budgetRinggit,
                    onValueChange = vm::onBudgetChange,
                    label = { Text(stringResource(R.string.kirim_budget)) },
                    singleLine = true,
                    shape = MaterialTheme.shapes.small,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Spacer(Modifier.height(10.dp))
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

            Spacer(Modifier.height(10.dp))
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

            Spacer(Modifier.height(16.dp))
            Button(
                onClick = vm::quote,
                enabled = form.canQuote && !state.isQuoting,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
            ) {
                if (state.isQuoting) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.kirim_get_quote), style = MaterialTheme.typography.labelLarge)
                }
            }
        }

        state.error?.let {
            Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error)
        }
        state.quote?.let { quote ->
            QuoteResult(quote)
            SubmissionForm(vm, state.addresses)
        }
    }
}

@Composable
private fun SubmissionForm(vm: KirimQuoteViewModel, addresses: List<Address>) {
    val state by vm.state.collectAsState()
    val form = state.form

    AppCard {
        OutlinedTextField(
            value = form.itemDescription,
            onValueChange = vm::onItemDescriptionChange,
            label = { Text(stringResource(R.string.kirim_item_description)) },
            minLines = 2,
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )

        if (form.kirimType == KirimType.HANTAR) {
            Spacer(Modifier.height(12.dp))
            Text(stringResource(R.string.kirim_origin_address), style = MaterialTheme.typography.labelLarge)
            Spacer(Modifier.height(6.dp))
            AddressChips(addresses, form.selectedOriginAddress, vm::onOriginAddressSelected)
        }

        Spacer(Modifier.height(12.dp))
        Text(stringResource(R.string.kirim_dest_address), style = MaterialTheme.typography.labelLarge)
        Spacer(Modifier.height(6.dp))
        AddressChips(addresses, form.selectedDestAddress, vm::onDestAddressSelected)
        if (addresses.isEmpty()) {
            Text(
                stringResource(R.string.kirim_no_addresses),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        Spacer(Modifier.height(16.dp))
        Button(
            onClick = vm::submitKirim,
            enabled = form.canSubmit && !state.isSubmitting,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) {
            if (state.isSubmitting) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(R.string.kirim_submit), style = MaterialTheme.typography.labelLarge)
            }
        }
    }
}

@Composable
private fun AddressChips(addresses: List<Address>, selected: Address?, onSelect: (Address) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        addresses.forEach { address ->
            FilterChip(
                selected = selected?.id == address.id,
                onClick = { onSelect(address) },
                label = { Text(address.label) },
            )
        }
    }
}

@Composable
private fun KirimCreatedResult(created: KirimCreated) {
    GradientHeroCard {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.onPrimary, modifier = Modifier.size(40.dp))
            Spacer(Modifier.height(12.dp))
            Text(
                stringResource(R.string.kirim_posted_title),
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onPrimary,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                stringResource(R.string.kirim_posted_reference, created.referenceCode),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.85f),
            )
        }
    }
}

@Composable
private fun QuoteResult(quote: KirimQuote) {
    AppCard {
        Text(stringResource(R.string.kirim_quote_title), style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.kirim_quote_corridor, quote.corridorKm, quote.corridorBand),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        if (quote.goodsBudgetSen.value > 0) {
            QuoteLine(stringResource(R.string.kirim_quote_goods_label), quote.goodsBudgetSen.format())
        }
        QuoteLine(stringResource(R.string.kirim_quote_delivery_label), quote.deliveryFeeSen.format())
        HorizontalDivider(Modifier.padding(vertical = 8.dp), color = MaterialTheme.colorScheme.outlineVariant)
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.kirim_quote_total_label), style = MaterialTheme.typography.titleMedium)
            Text(
                quote.orderTotalSen.format(),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
            )
        }
    }
}

@Composable
private fun QuoteLine(label: String, value: String) {
    Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun FlowOfChips(content: @Composable () -> Unit) {
    // A horizontally scrollable row, not a FlowRow: keeps every category
    // reachable without pulling in a new dependency for five chips.
    Row(
        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) { content() }
}
