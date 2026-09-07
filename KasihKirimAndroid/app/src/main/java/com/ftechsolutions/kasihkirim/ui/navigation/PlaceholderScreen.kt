package com.ftechsolutions.kasihkirim.ui.navigation

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R

/**
 * An explicit "not built yet" screen. Deliberately not a mock: it fetches
 * nothing, fabricates nothing, and cannot be mistaken for working behaviour
 * (§40 -- a mock must never silently become production).
 */
@Composable
fun PlaceholderScreen(destination: Destination) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(stringResource(destination.labelRes), style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(8.dp))
        Text(stringResource(R.string.phase1_placeholder), style = MaterialTheme.typography.bodyMedium)
    }
}
