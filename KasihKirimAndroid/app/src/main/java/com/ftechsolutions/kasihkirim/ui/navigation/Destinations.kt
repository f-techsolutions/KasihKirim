package com.ftechsolutions.kasihkirim.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Dashboard
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.PointOfSale
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.ReceiptLong
import androidx.compose.material.icons.filled.Route
import androidx.compose.material.icons.filled.Storefront
import androidx.compose.ui.graphics.vector.ImageVector
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.UserRole

/**
 * Tabs are chosen from the JWT role claim. This is a CONVENIENCE, not a
 * control: hiding a tab hides nothing from a determined client. RLS decides
 * what any of these screens can actually read, and admin surfaces are not in
 * this app at all -- they live in the separate console.
 */
enum class Destination(val route: String, val labelRes: Int, val icon: ImageVector) {
    HOME("home", R.string.nav_home, Icons.Filled.Home),
    SEND("send", R.string.nav_send, Icons.Filled.LocalShipping),
    BOARD("board", R.string.nav_board, Icons.Filled.Dashboard),
    ORDERS("orders", R.string.nav_orders, Icons.Filled.ReceiptLong),
    PROFILE("profile", R.string.nav_profile, Icons.Filled.Person),
    TRIPS("trips", R.string.nav_trips, Icons.Filled.Route),
    EARNINGS("earnings", R.string.nav_earnings, Icons.Filled.Payments),
    MUATAN_JUAL("muatan-jual", R.string.nav_muatan_jual, Icons.Filled.Storefront),
    SALES("sales", R.string.nav_sales, Icons.Filled.PointOfSale),
}

fun tabsFor(role: UserRole): List<Destination> = when (role) {
    UserRole.CARRIER -> listOf(
        Destination.HOME, Destination.TRIPS, Destination.ORDERS,
        Destination.EARNINGS, Destination.PROFILE,
    )
    UserRole.SELLER -> listOf(
        Destination.HOME, Destination.MUATAN_JUAL, Destination.ORDERS,
        Destination.SALES, Destination.PROFILE,
    )
    else -> listOf(
        Destination.HOME, Destination.SEND, Destination.BOARD,
        Destination.ORDERS, Destination.PROFILE,
    )
}
