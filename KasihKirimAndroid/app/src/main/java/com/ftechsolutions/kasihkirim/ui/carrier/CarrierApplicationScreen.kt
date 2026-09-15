@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.carrier

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.CarrierProfile
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.CommunityPicker
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

/** Mirrors SalesScreen's own apply-form/pending-status split (SellerApplicationScreen/
 *  SellerStatusScreen), minus the product catalog: once APPROVED, ProfileScreen
 *  stops offering this screen at all, since Board/Trips/Vehicles/Deliveries/
 *  Earnings already are the carrier's working screens. */
@Composable
fun CarrierApplicationScreen(vm: CarrierApplicationViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.carrier_apply_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when {
                state.isLoading && state.carrier == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                state.carrier == null -> CarrierApplicationForm(vm)
                else -> CarrierStatusScreen(state.carrier!!)
            }
        }
    }
}

@Composable
private fun CarrierApplicationForm(vm: CarrierApplicationViewModel) {
    val state by vm.state.collectAsState()
    val form = state.applicationForm

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { Spacer(Modifier.height(4.dp)) }
        item {
            Text(
                stringResource(R.string.carrier_apply_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        item {
            AppCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    CommunityPicker(
                        label = stringResource(R.string.carrier_apply_community),
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
                    Button(
                        onClick = vm::submitApplication,
                        enabled = form.canSubmit && !state.isSubmittingApplication,
                        shape = MaterialTheme.shapes.medium,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                    ) {
                        if (state.isSubmittingApplication) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.carrier_apply_submit))
                        }
                    }
                }
            }
        }
        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun CarrierStatusScreen(carrier: CarrierProfile) {
    Column(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        AppCard {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                StatusBadge(
                    carrier.status.labelMs,
                    tone = if (carrier.status == SellerStatus.REJECTED || carrier.status == SellerStatus.SUSPENDED ||
                        carrier.status == SellerStatus.REVOKED
                    ) {
                        BadgeTone.ERROR
                    } else {
                        BadgeTone.WARNING
                    },
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    stringResource(R.string.carrier_status_pending_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}
