package com.ftechsolutions.kasihkirim.ui.profile

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Redeem
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.domain.model.Badge
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge

@Composable
fun ProfileScreen(
    user: AuthUser,
    vm: AuthViewModel,
    profileVm: ProfileViewModel,
    onOpenAddresses: () -> Unit,
    onOpenServiceability: () -> Unit,
    onOpenSales: () -> Unit,
    onOpenCarrierApplication: () -> Unit,
    onOpenPromotions: () -> Unit,
    onOpenCarrierLots: () -> Unit,
) {
    val profileState by profileVm.state.collectAsState()

    Column(
        Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Spacer(Modifier.height(12.dp))
        IdentityCard(user)

        if (profileState.badges.isNotEmpty()) {
            BadgesRow(profileState.badges)
        }

        AppCard {
            ActionRow(
                icon = Icons.Filled.LocationOn,
                label = stringResource(R.string.addresses_title),
                onClick = onOpenAddresses,
            )
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            ActionRow(
                icon = Icons.Filled.MyLocation,
                label = stringResource(R.string.serviceability_title),
                onClick = onOpenServiceability,
            )
            // tabsFor(SELLER) is the only place Destination.SALES is a tab
            // (Destinations.kt) -- everyone else needs a way in before they
            // hold the role at all, since applying is exactly how they'd
            // ever get it. Same route as the tab; SalesScreen renders the
            // right state on its own (apply form / pending / catalog).
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            ActionRow(
                icon = Icons.Filled.Storefront,
                label = stringResource(
                    if (UserRole.SELLER in user.roles) R.string.profile_my_sales else R.string.profile_become_seller,
                ),
                onClick = onOpenSales,
            )
            // Unlike Sales, once the carrier role is held there is nothing
            // further this row needs to offer -- Board/Trips/Vehicles/
            // Deliveries/Earnings (existing tabs) are the carrier's working
            // screens, and CarrierApplicationScreen has nothing to add past
            // onboarding. So this row disappears entirely on approval,
            // rather than switching to a "my carrier" destination like
            // Sales does.
            if (UserRole.CARRIER !in user.roles) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                ActionRow(
                    icon = Icons.Filled.LocalShipping,
                    label = stringResource(R.string.profile_become_carrier),
                    onClick = onOpenCarrierApplication,
                )
            }
            // Muatan Jual (Phase 3, 0047): a carrier selling their own
            // carried stock -- FR-440's "carrier applies for the seller
            // role" is carrier-only, unlike Kongsi & Untung below (any
            // profile). ref.compliance_state stays NOT_READY regardless;
            // this row and CarrierLotsScreen exist so onboarding and
            // listing prep can happen ahead of go-live.
            if (UserRole.CARRIER in user.roles) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                ActionRow(
                    icon = Icons.Filled.Inventory2,
                    label = stringResource(R.string.profile_muatan_jual_lots),
                    onClick = onOpenCarrierLots,
                )
            }
            // Kongsi & Untung (0045): a promoter is any profile, not a role
            // held or applied for -- unlike Sales/Carrier above, this row
            // never disappears or changes label.
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            ActionRow(
                icon = Icons.Filled.Redeem,
                label = stringResource(R.string.profile_kongsi_untung),
                onClick = onOpenPromotions,
            )
        }

        Spacer(Modifier.weight(1f))
        OutlinedButton(
            onClick = vm::signOut,
            colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.error),
            border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.4f)),
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) {
            Icon(Icons.Filled.Logout, contentDescription = null, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.auth_sign_out))
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun IdentityCard(user: AuthUser) {
    AppCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Surface(
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier.size(52.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        (user.email?.firstOrNull() ?: '?').uppercase(),
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onPrimaryContainer,
                    )
                }
            }
            Spacer(Modifier.width(14.dp))
            Column {
                Text(
                    user.email ?: "-",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    StatusBadge(user.primaryRole.wire.replaceFirstChar { it.uppercase() }, tone = BadgeTone.INFO)
                    user.accountStatus?.let { StatusBadge(it.replaceFirstChar { c -> c.uppercase() }, tone = BadgeTone.NEUTRAL) }
                }
            }
        }
    }
}

@Composable
private fun BadgesRow(badges: List<Badge>) {
    AppCard {
        Text(stringResource(R.string.profile_badges_title), style = MaterialTheme.typography.titleSmall)
        Spacer(Modifier.height(10.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(badges, key = { it.slug }) { badge ->
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        modifier = Modifier.size(48.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(badge.icon, style = MaterialTheme.typography.titleLarge)
                        }
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        badge.nameMs,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun ActionRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.secondaryContainer,
            modifier = Modifier.size(36.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Icon(
                    icon,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSecondaryContainer,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
