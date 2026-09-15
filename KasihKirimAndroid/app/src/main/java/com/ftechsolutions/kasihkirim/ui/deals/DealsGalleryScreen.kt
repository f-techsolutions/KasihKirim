@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.deals

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.DealCampaign
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard

/** The buyer-facing deals gallery (0048_promotions_gallery.sql): a small,
 *  admin-curated set of featured products. Reached from Home rather than a
 *  bottom tab, the same reasoning BUY_ROUTE itself lives off Home instead
 *  of crowding an already-full per-role tab row (Destinations.kt).
 *  Tapping a deal opens BuyScreen filtered to that product's own title --
 *  there is no separate per-product detail screen anywhere in this app
 *  (BuyListing has none either), so reusing BuyScreen's existing search is
 *  the smallest way to land the buyer on the right listing. */
@Composable
fun DealsGalleryScreen(vm: DealsGalleryViewModel, onBack: () -> Unit, onOpenDeal: (DealCampaign) -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.deals_title)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding).padding(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item { Spacer(Modifier.height(4.dp)) }

            state.error?.let {
                item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }
            }
            if (state.deals.isEmpty() && !state.isLoading && state.error == null) {
                item { EmptyStateCard(stringResource(R.string.deals_empty)) }
            }
            items(state.deals, key = { it.id }) { deal ->
                DealCard(deal, onClick = { onOpenDeal(deal) })
            }
            item { Spacer(Modifier.height(8.dp)) }
        }
    }
}

@Composable
private fun DealCard(deal: DealCampaign, onClick: () -> Unit) {
    AppCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Filled.LocalOffer,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
            )
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(deal.title, style = MaterialTheme.typography.titleMedium)
                if (deal.subtitle != null) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        deal.subtitle,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    "${deal.productTitle} · ${deal.priceSen.format()}/${deal.unit}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = stringResource(R.string.deals_view_product),
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
