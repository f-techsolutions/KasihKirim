package com.ftechsolutions.kasihkirim.ui.navigation

import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.UserRole

/**
 * Tabs are chosen from the JWT role claim. This is a CONVENIENCE, not a
 * control: hiding a tab hides nothing from a determined client. RLS decides
 * what any of these screens can actually read, and admin surfaces are not in
 * this app at all -- they live in the separate console.
 */
enum class Destination(val route: String, val labelRes: Int) {
    HOME("home", R.string.nav_home),
    SEND("send", R.string.nav_send),
    BOARD("board", R.string.nav_board),
    ORDERS("orders", R.string.nav_orders),
    PROFILE("profile", R.string.nav_profile),
    TRIPS("trips", R.string.nav_trips),
    EARNINGS("earnings", R.string.nav_earnings),
    MUATAN_JUAL("muatan-jual", R.string.nav_muatan_jual),
    SALES("sales", R.string.nav_sales),
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
