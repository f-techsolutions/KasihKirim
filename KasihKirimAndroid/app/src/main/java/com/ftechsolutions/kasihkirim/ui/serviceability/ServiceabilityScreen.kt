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
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.Serviceability

@Composable
fun ServiceabilityScreen(vm: ServiceabilityViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()
    val form = state.form

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.serviceability_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Spacer(Modifier.height(8.dp))

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

            if ((form.selectedOrigin != null && form.selectedOrigin.nodeId == null) ||
                (form.selectedDest != null && form.selectedDest.nodeId == null)
            ) {
                Text(stringResource(R.string.serviceability_no_node), color = MaterialTheme.colorScheme.error)
            }

            Spacer(Modifier.height(8.dp))
            Button(
                onClick = vm::check,
                enabled = form.canCheck && !state.isChecking,
                modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
            ) {
                if (state.isChecking) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.serviceability_check))
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
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp)) {
            when (result) {
                is Serviceability.Serviceable -> {
                    Text(stringResource(R.string.serviceability_ok), style = MaterialTheme.typography.titleMedium)
                    Text("${result.originDistrict} → ${result.destDistrict}", style = MaterialTheme.typography.bodyMedium)
                    Text(
                        stringResource(R.string.serviceability_distance, result.distanceKm, result.estMinutes),
                        style = MaterialTheme.typography.bodySmall,
                    )
                    if (result.requiresWaterTransport) {
                        Text(stringResource(R.string.serviceability_water), style = MaterialTheme.typography.bodySmall)
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
