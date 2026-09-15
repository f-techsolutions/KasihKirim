@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.serviceability

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.CommunityPicker

@Composable
fun ServiceabilityScreen(vm: ServiceabilityViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()
    val form = state.form

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.serviceability_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Spacer(Modifier.height(4.dp))

            AppCard {
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

                if ((form.selectedOrigin != null && form.selectedOrigin.nodeId == null) ||
                    (form.selectedDest != null && form.selectedDest.nodeId == null)
                ) {
                    Spacer(Modifier.height(8.dp))
                    Text(stringResource(R.string.serviceability_no_node), color = MaterialTheme.colorScheme.error)
                }

                Spacer(Modifier.height(14.dp))
                Button(
                    onClick = vm::check,
                    enabled = form.canCheck && !state.isChecking,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                ) {
                    if (state.isChecking) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.serviceability_check))
                    }
                }
            }

            state.error?.let {
                Text(stringResource(R.string.err_unexpected), color = MaterialTheme.colorScheme.error)
            }
            state.result?.let { ServiceabilityResult(it) }

            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun ServiceabilityResult(result: Serviceability) {
    AppCard {
        when (result) {
            is Serviceability.Serviceable -> {
                Text(stringResource(R.string.serviceability_ok), style = MaterialTheme.typography.titleMedium)
                Text("${result.originDistrict} → ${result.destDistrict}", style = MaterialTheme.typography.bodyMedium)
                Text(
                    stringResource(R.string.serviceability_distance, result.distanceKm, result.estMinutes),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (result.requiresWaterTransport) {
                    Text(
                        stringResource(R.string.serviceability_water),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            is Serviceability.OriginNotActive -> Text(
                stringResource(R.string.serviceability_origin_not_active, result.district),
                color = MaterialTheme.colorScheme.error,
            )
            is Serviceability.DestinationNotActive -> Text(
                stringResource(R.string.serviceability_dest_not_active, result.district),
                color = MaterialTheme.colorScheme.error,
            )
            is Serviceability.NoRoute -> Text(
                stringResource(R.string.serviceability_no_route),
                color = MaterialTheme.colorScheme.error,
            )
            is Serviceability.GeographyUnknown -> Text(
                stringResource(R.string.serviceability_unknown),
                color = MaterialTheme.colorScheme.error,
            )
        }
    }
}
