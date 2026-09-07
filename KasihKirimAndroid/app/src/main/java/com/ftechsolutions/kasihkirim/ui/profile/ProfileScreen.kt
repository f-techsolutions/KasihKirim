package com.ftechsolutions.kasihkirim.ui.profile

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel

@Composable
fun ProfileScreen(user: AuthUser, vm: AuthViewModel, onOpenAddresses: () -> Unit) {
    Column(Modifier.fillMaxSize().padding(24.dp)) {
        Text(stringResource(R.string.nav_profile), style = MaterialTheme.typography.headlineSmall)
        Spacer(Modifier.height(16.dp))
        Text(user.email ?: "-", style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.height(4.dp))
        Text("Peranan: " + user.roles.joinToString { it.wire }.ifEmpty { "customer" },
            style = MaterialTheme.typography.bodySmall)
        user.accountStatus?.let {
            Spacer(Modifier.height(4.dp))
            Text("Status: $it", style = MaterialTheme.typography.bodySmall)
        }
        Spacer(Modifier.height(16.dp))
        OutlinedButton(
            onClick = onOpenAddresses,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) { Text(stringResource(R.string.addresses_title)) }

        Spacer(Modifier.weight(1f))
        OutlinedButton(
            onClick = vm::signOut,
            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
        ) { Text(stringResource(R.string.auth_sign_out)) }
    }
}
