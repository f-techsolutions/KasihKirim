@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.buy

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.Store
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader

@Composable
fun BuyScreen(vm: BuyViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.buy_title)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
                actions = {
                    BadgedBox(
                        badge = { if (state.cartCount > 0) Badge { Text(state.cartCount.toString()) } },
                    ) {
                        IconButton(onClick = { vm.toggleCart(true) }) {
                            Icon(Icons.Filled.ShoppingCart, contentDescription = stringResource(R.string.buy_cart))
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item {
                    Spacer(Modifier.height(4.dp))
                    OutlinedTextField(
                        value = state.searchQuery,
                        onValueChange = vm::onSearchQueryChange,
                        label = { Text(stringResource(R.string.buy_search_hint)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (state.listings.isEmpty() && !state.isLoading) {
                    item { EmptyStateCard(stringResource(R.string.buy_empty)) }
                }
                items(state.listings, key = { it.id }) { listing ->
                    ListingCard(listing, onAdd = { vm.addToCart(listing.id) })
                }
                state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
                item { Spacer(Modifier.height(24.dp)) }
            }
        }
    }

    if (state.showCart) {
        CartSheet(vm)
    }
}

@Composable
private fun ListingCard(listing: BuyListing, onAdd: () -> Unit) {
    AppCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(listing.title, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(2.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Filled.Store,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        listing.sellerName,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text("${listing.priceSen.format()} / ${listing.unit}", style = MaterialTheme.typography.bodyMedium)
            }
            FilledIconButton(onClick = onAdd) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.buy_add_to_cart))
            }
        }
    }
}

@Composable
private fun CartSheet(vm: BuyViewModel) {
    val state by vm.state.collectAsState()

    ModalBottomSheet(onDismissRequest = { vm.toggleCart(false) }) {
        if (state.checkoutResult != null) {
            CheckoutSuccessContent(vm)
            return@ModalBottomSheet
        }

        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            ScreenHeader(stringResource(R.string.buy_cart))

            if (state.cart.isEmpty()) {
                EmptyStateCard(stringResource(R.string.buy_cart_empty))
            } else {
                state.cart.forEach { line -> CartLineRow(line, vm) }

                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(stringResource(R.string.buy_cart_total), style = MaterialTheme.typography.titleMedium)
                    Text(
                        Sen(state.cartTotalSen).format(),
                        style = MaterialTheme.typography.titleMedium,
                    )
                }

                if (state.cartSpansMultipleSellers) {
                    Text(
                        stringResource(R.string.buy_multi_seller_hint),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                if (state.addresses.isEmpty()) {
                    Text(
                        stringResource(R.string.buy_no_address),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                } else {
                    Text(stringResource(R.string.buy_deliver_to), style = MaterialTheme.typography.labelLarge)
                    state.addresses.forEach { address ->
                        FilterChip(
                            selected = state.selectedAddressId == address.id,
                            onClick = { vm.onAddressSelected(address.id) },
                            label = { Text(address.label) },
                        )
                    }
                }

                if (!state.cartSpansMultipleSellers) {
                    OutlinedTextField(
                        value = state.voucherCode,
                        onValueChange = vm::onVoucherCodeChange,
                        label = { Text(stringResource(R.string.buy_voucher_code)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                Button(
                    onClick = vm::checkout,
                    enabled = !state.isCheckingOut && state.selectedAddressId != null,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                ) {
                    if (state.isCheckingOut) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Text(stringResource(R.string.buy_checkout))
                    }
                }
            }

            state.error?.let { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }
        }
    }
}

@Composable
private fun CartLineRow(line: CartLine, vm: BuyViewModel) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.weight(1f)) {
            Text(line.title, style = MaterialTheme.typography.bodyLarge)
            Text(
                line.lineTotalSen.format(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        IconButton(onClick = { vm.updateCartQuantity(line.cartItemId, line.quantity - 1) }) {
            Icon(Icons.Filled.Remove, contentDescription = stringResource(R.string.buy_decrease_quantity))
        }
        Text(line.quantity.toString(), style = MaterialTheme.typography.titleMedium)
        IconButton(onClick = { vm.updateCartQuantity(line.cartItemId, line.quantity + 1) }) {
            Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.buy_increase_quantity))
        }
    }
}

@Composable
private fun CheckoutSuccessContent(vm: BuyViewModel) {
    val state by vm.state.collectAsState()
    val result = state.checkoutResult ?: return

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ScreenHeader(stringResource(R.string.buy_checkout_success))
        result.orders.forEach { order ->
            AppCard {
                Text(order.referenceCode, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text("${stringResource(R.string.buy_order_total)}: ${order.totalSen.format()}")
                if (order.discountSen.value > 0) {
                    Text(
                        "${stringResource(R.string.buy_order_discount)}: -${order.discountSen.format()}",
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        }
        Button(
            onClick = vm::dismissCheckoutResult,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) { Text(stringResource(R.string.buy_done)) }
    }
}
