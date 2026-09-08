package com.ftechsolutions.kasihkirim.ui.earnings

import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.ui.auth.messageRes

@Composable
fun EarningsScreen(vm: EarningsViewModel) {
    val state by vm.state.collectAsState()

    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(R.string.earnings_title), style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))

        when {
            state.isLoading -> CircularProgressIndicator()
            state.error != null -> Text(
                stringResource(state.error!!.messageRes()),
                color = MaterialTheme.colorScheme.error,
            )
            state.earnings != null -> EarningsCard(state.earnings!!)
        }
    }
}

@Composable
private fun EarningsCard(earnings: Earnings) {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            EarningsRow(stringResource(R.string.earnings_available), earnings.availableSen.format())
            EarningsRow(stringResource(R.string.earnings_pending), earnings.pendingSen.format())
            earnings.codHeldSen?.let { EarningsRow(stringResource(R.string.earnings_cod_held), it.format()) }
            earnings.floatLimitSen?.let { EarningsRow(stringResource(R.string.earnings_float_limit), it.format()) }
        }
    }
}

@Composable
private fun EarningsRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.titleMedium)
    }
}
