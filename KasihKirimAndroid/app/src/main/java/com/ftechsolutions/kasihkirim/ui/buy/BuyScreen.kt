@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.buy

import android.content.Intent
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ReceiptLong
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.Store
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.CartLine
import com.ftechsolutions.kasihkirim.domain.model.BuyListing
import com.ftechsolutions.kasihkirim.domain.model.CheckoutOrderSummary
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.EmptyStateCard
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader

@Composable
fun BuyScreen(vm: BuyViewModel, onBack: () -> Unit, onOpenOrders: () -> Unit) {
    val state by vm.state.collectAsState()
    val context = LocalContext.current

    // One-shot: a Custom Tab launch is a side effect, not something a
    // recomposition should repeat. vm.onPaymentUrlLaunched() clears the
    // field the moment it fires.
    LaunchedEffect(state.pendingPaymentUrl) {
        val url = state.pendingPaymentUrl ?: return@LaunchedEffect
        CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
        vm.onPaymentUrlLaunched()
    }

    // Kongsi & Untung: the same one-shot pattern as pendingPaymentUrl above,
    // launching Android's own share sheet instead of a Custom Tab.
    val shareMessageTemplate = stringResource(R.string.buy_share_earn_message)
    LaunchedEffect(state.pendingShare) {
        val share = state.pendingShare ?: return@LaunchedEffect
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, shareMessageTemplate.format(share.productTitle, share.shareLink))
        }
        context.startActivity(Intent.createChooser(intent, null))
        vm.onShareLaunched()
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.buy_title)) },
                navigationIcon = { TextButton(onClick = onBack) { Text(stringResource(R.string.back)) } },
                actions = {
                    IconButton(onClick = onOpenOrders) {
                        Icon(Icons.Filled.ReceiptLong, contentDescription = stringResource(R.string.buy_orders_action))
                    }
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
                if (state.isLoading && state.listings.isEmpty()) {
                    item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
                } else if (state.listings.isEmpty() && state.error == null) {
                    // Found on-device: a background loadCart()/loadAddresses()
                    // failure writes into this same state.error, so without
                    // this check a real error rendered alongside a confusing
                    // "no products" claim that wasn't actually true.
                    item { EmptyStateCard(stringResource(R.string.buy_empty)) }
                }
                items(state.listings, key = { it.id }) { listing ->
                    ListingCard(
                        listing = listing,
                        isAdding = state.addingToCartProductId == listing.id,
                        isSharing = state.isSharingProductId == listing.id,
                        onAdd = { vm.addToCart(listing.id) },
                        onShare = { vm.shareProduct(listing) },
                    )
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
private fun ListingCard(
    listing: BuyListing,
    isAdding: Boolean,
    isSharing: Boolean,
    onAdd: () -> Unit,
    onShare: () -> Unit,
) {
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
            // Kongsi & Untung (0045): mints (or re-fetches) this buyer's own
            // share code for the product and opens the Android share sheet.
            // A no-op-with-error while the feature is off, surfaced the same
            // way any other RPC error is -- not hidden behind a role check,
            // since anyone can be a promoter.
            IconButton(onClick = onShare, enabled = !isSharing) {
                if (isSharing) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.Share, contentDescription = stringResource(R.string.buy_share_earn))
                }
            }
            FilledIconButton(onClick = onAdd, enabled = !isAdding) {
                if (isAdding) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.buy_add_to_cart))
                }
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

                    // Sandbox-only (Billplz, P2-A): selecting this and having
                    // it actually work both depend on a project deliberately
                    // enabling a non-COD method server-side
                    // (ref.app_config.payment_methods_enabled) -- picking it
                    // where that hasn't happened surfaces as an ordinary,
                    // readable checkout error, not a crash. Hidden for a
                    // multi-seller cart: one online payment covers exactly
                    // one order.
                    Text(stringResource(R.string.buy_payment_method), style = MaterialTheme.typography.labelLarge)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(
                            selected = state.paymentMethod == "COD",
                            onClick = { vm.onPaymentMethodSelected("COD") },
                            label = { Text(stringResource(R.string.buy_payment_method_cod)) },
                        )
                        FilterChip(
                            selected = state.paymentMethod == "FPX",
                            onClick = { vm.onPaymentMethodSelected("FPX") },
                            label = { Text(stringResource(R.string.buy_payment_method_online)) },
                        )
                    }
                }

                Button(
                    onClick = vm::requestCheckout,
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

    // Found missing in review: this was the one real-money commitment in the
    // whole buyer flow with no confirmation step at all (COD needs no
    // further gate once placed either).
    if (state.showCheckoutConfirm) {
        AlertDialog(
            onDismissRequest = vm::dismissCheckoutConfirm,
            title = { Text(stringResource(R.string.buy_checkout_confirm_title)) },
            text = { Text(stringResource(R.string.buy_checkout_confirm_body)) },
            confirmButton = {
                TextButton(onClick = vm::checkout) { Text(stringResource(R.string.buy_checkout_confirm_ok)) }
            },
            dismissButton = {
                TextButton(onClick = vm::dismissCheckoutConfirm) { Text(stringResource(R.string.buy_cancel)) }
            },
        )
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
    // A multi-seller cart is forced to COD at checkout (BuyViewModel), so a
    // non-COD method only ever appears on a single-order result.
    val paymentOrder = result.orders.singleOrNull()?.takeIf { it.paymentMethod != "COD" }

    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        ScreenHeader(stringResource(R.string.buy_checkout_success))
        result.orders.forEach { order ->
            AppCard {
                Text(order.referenceCode, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(4.dp))
                Text("${stringResource(R.string.buy_order_goods_subtotal)}: ${order.goodsSubtotalSen.format()}")
                Text("${stringResource(R.string.buy_order_delivery_fee)}: ${order.deliveryFeeSen.format()}")
                if (order.discountSen.value > 0) {
                    Text(
                        "${stringResource(R.string.buy_order_discount)}: -${order.discountSen.format()}",
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text(
                    "${stringResource(R.string.buy_order_total)}: ${order.totalSen.format()}",
                    style = MaterialTheme.typography.titleSmall,
                )
            }
        }

        if (paymentOrder != null) {
            PaymentStatusSection(vm, paymentOrder)
        }

        state.error?.let { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) }

        Button(
            onClick = vm::dismissCheckoutResult,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) { Text(stringResource(R.string.buy_done)) }
    }
}

/** The bit that plugs the new Billplz payment-intent flow into checkout
 *  (0034): the order above is prepaid and unpaid, and needs a hosted page
 *  opened and its capture watched for -- see BuyViewModel.payNow /
 *  startPollingPayment for why this is polling rather than push. */
@Composable
private fun PaymentStatusSection(vm: BuyViewModel, order: CheckoutOrderSummary) {
    val state by vm.state.collectAsState()
    val status = state.paymentStatus

    AppCard {
        when {
            status?.status == "SUCCEEDED" || status?.status == "CAPTURED" ->
                Text(stringResource(R.string.buy_payment_succeeded), color = MaterialTheme.colorScheme.primary)

            status?.status == "FAILED" || status?.status == "CANCELLED" || status?.status == "EXPIRED" ->
                Text(stringResource(R.string.buy_payment_failed), color = MaterialTheme.colorScheme.error)

            state.isPollingPayment -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(10.dp))
                Text(stringResource(R.string.buy_payment_waiting))
            }

            else -> Button(
                onClick = { vm.payNow(order.orderId) },
                enabled = !state.isPreparingPayment,
                shape = MaterialTheme.shapes.medium,
                modifier = Modifier.fillMaxWidth().heightIn(min = 46.dp),
            ) {
                if (state.isPreparingPayment) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                } else {
                    Text(stringResource(R.string.buy_payment_pay_now))
                }
            }
        }

        if (state.isPollingPayment) {
            Spacer(Modifier.height(8.dp))
            TextButton(onClick = { vm.refreshPaymentStatus(order.orderId) }) {
                Text(stringResource(R.string.buy_payment_refresh_status))
            }
        }
    }
}
