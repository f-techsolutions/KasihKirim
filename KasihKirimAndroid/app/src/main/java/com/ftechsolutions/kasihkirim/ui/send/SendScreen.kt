@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.send

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.ui.auth.messageRes

/** Quote only -- there is nowhere for a "submit" button to go yet.
 *  rpc_create_kirim doesn't exist in the backend (docs/
 *  CLAUDE_IMPLEMENTATION_PLAN.md §3 gap list); this screen calls
 *  rpc_quote_kirim, the one part of Phase 3 that's actually callable today. */
@Composable
fun SendScreen(vm: KirimQuoteViewModel) {
    val state by vm.state.collectAsState()
    val form = state.form

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.kirim_title), style = MaterialTheme.typography.headlineSmall)
        Text(stringResource(R.string.kirim_quote_only_notice), style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(8.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            KirimType.entries.filter { it != KirimType.PASARAN }.forEach { type ->
                FilterChip(
                    selected = form.kirimType == type,
                    onClick = { vm.onKirimTypeChange(type) },
                    label = { Text(stringResource(if (type == KirimType.BELI) R.string.kirim_type_beli else R.string.kirim_type_hantar)) },
                )
            }
        }

        Text(stringResource(R.string.kirim_category), style = MaterialTheme.typography.labelLarge)
        FlowOfChips {
            KirimCategory.entries.forEach { category ->
                FilterChip(
                    selected = form.category == category,
                    onClick = { vm.onCategorySelected(category) },
                    label = { Text(category.nameMs) },
                )
            }
        }

        OutlinedTextField(
            value = form.weightGrams,
            onValueChange = vm::onWeightChange,
            label = { Text(stringResource(R.string.kirim_weight)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )

        if (form.kirimType == KirimType.BELI) {
            OutlinedTextField(
                value = form.budgetRinggit,
                onValueChange = vm::onBudgetChange,
                label = { Text(stringResource(R.string.kirim_budget)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
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

        Spacer(Modifier.height(8.dp))
        Button(
            onClick = vm::quote,
            enabled = form.canQuote && !state.isQuoting,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) {
            if (state.isQuoting) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(R.string.kirim_get_quote))
            }
        }

        state.error?.let {
            Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error)
        }
        state.quote?.let { QuoteResult(it) }

        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun QuoteResult(quote: KirimQuote) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(stringResource(R.string.kirim_quote_title), style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(R.string.kirim_quote_corridor, quote.corridorKm, quote.corridorBand),
                style = MaterialTheme.typography.bodySmall,
            )
            if (quote.goodsBudgetSen.value > 0) {
                Text(stringResource(R.string.kirim_quote_goods, quote.goodsBudgetSen.format()))
            }
            Text(stringResource(R.string.kirim_quote_delivery, quote.deliveryFeeSen.format()))
            Text(stringResource(R.string.kirim_quote_total, quote.orderTotalSen.format()), style = MaterialTheme.typography.titleMedium)
        }
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
