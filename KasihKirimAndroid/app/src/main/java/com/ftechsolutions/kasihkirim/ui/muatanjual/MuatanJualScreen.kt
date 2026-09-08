package com.ftechsolutions.kasihkirim.ui.muatanjual

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun MuatanJualScreen(vm: MuatanJualViewModel) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Spacer(Modifier.height(16.dp))
            Text(stringResource(R.string.muatan_jual_title), style = MaterialTheme.typography.headlineSmall)
        }
        item { NoticeCard() }

        if (state.listings.isEmpty() && !state.isLoading) {
            item { Text(stringResource(R.string.muatan_jual_empty)) }
        }
        items(state.listings, key = { it.id }) { listing -> LotCard(listing) }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun NoticeCard() {
    ElevatedCard {
        Text(
            stringResource(R.string.muatan_jual_notice),
            modifier = Modifier.padding(16.dp),
            style = MaterialTheme.typography.bodyMedium,
        )
    }
}

@Composable
private fun LotCard(listing: MuatanJualListing) {
    ElevatedCard {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(listing.title, style = MaterialTheme.typography.titleMedium)
            Text(
                stringResource(
                    R.string.muatan_jual_price_per_unit,
                    listing.pricePerUnitSen.format(),
                    listing.unit,
                ),
                style = MaterialTheme.typography.bodyMedium,
            )
            Text(
                stringResource(R.string.muatan_jual_qty_available, formatQty(listing.qtyAvailable), listing.unit),
                style = MaterialTheme.typography.bodySmall,
            )
            listing.sellBy?.let {
                Text(stringResource(R.string.muatan_jual_sell_by, formatSellBy(it)), style = MaterialTheme.typography.bodySmall)
            }
            if (listing.handlingFlags.isNotEmpty()) {
                Text(
                    listing.handlingFlags.joinToString(" · ") { it.labelMs },
                    style = MaterialTheme.typography.labelSmall,
                )
            }
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
