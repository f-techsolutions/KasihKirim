package com.ftechsolutions.kasihkirim.ui.home

import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.AuthUser

@Composable
fun HomeScreen(user: AuthUser) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(4.dp))
        Text(stringResource(R.string.tagline), style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.height(24.dp))
        // Roles shown for transparency during Phase 1. They come from the JWT
        // claim; they do not grant anything.
        Text("Peranan: " + user.roles.joinToString { it.wire }.ifEmpty { "customer" },
            style = MaterialTheme.typography.bodySmall)
        Spacer(Modifier.height(16.dp))
        Text(stringResource(R.string.phase1_placeholder),
            style = MaterialTheme.typography.bodyMedium)
    }
}
