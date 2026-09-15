package com.ftechsolutions.kasihkirim.ui.muatanjual

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun MuatanJualScreen(vm: MuatanJualViewModel) {
    val state by vm.state.collectAsState()

    // See BoardScreen's identical comment: init{}'s one-shot load() doesn't
    // refire when this tab is re-entered without this.
    LaunchedEffect(Unit) { vm.load() }

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Spacer(Modifier.height(12.dp))
            ScreenHeader(stringResource(R.string.muatan_jual_title))
        }
        item { NoticeCard() }

        if (state.listings.isEmpty() && !state.isLoading && state.error == null) {
            item { EmptyStateCard(stringResource(R.string.muatan_jual_empty)) }
        }
        items(state.listings, key = { it.id }) { listing -> LotCard(listing) }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun NoticeCard() {
    Surface(
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.tertiaryContainer,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
            Icon(
                Icons.Filled.Info,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onTertiaryContainer,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                stringResource(R.string.muatan_jual_notice),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onTertiaryContainer,
            )
        }
    }
}

@Composable
private fun LotCard(listing: MuatanJualListing) {
    AppCard {
        Text(listing.title, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(4.dp))
        Text(
            stringResource(
                R.string.muatan_jual_price_per_unit,
                listing.pricePerUnitSen.format(),
                listing.unit,
            ),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
        )
        Text(
            stringResource(R.string.muatan_jual_qty_available, formatQty(listing.qtyAvailable), listing.unit),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        listing.sellBy?.let {
            Text(
                stringResource(R.string.muatan_jual_sell_by, formatSellBy(it)),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (listing.handlingFlags.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Text(
                listing.handlingFlags.joinToString(" · ") { it.labelMs },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

private fun formatQty(qty: Double): String =
    if (qty == qty.toLong().toDouble()) qty.toLong().toString() else "%.2f".format(qty)

private fun formatSellBy(iso: String): String = try {
    DateTimeFormatter.ofPattern("d MMM yyyy").withZone(ZoneId.systemDefault()).format(Instant.parse(iso))
} catch (e: Exception) {
    iso
}
