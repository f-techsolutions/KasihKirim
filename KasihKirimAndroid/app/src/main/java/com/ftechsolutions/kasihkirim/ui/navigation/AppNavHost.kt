package com.ftechsolutions.kasihkirim.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.ui.addresses.AddressesScreen
import com.ftechsolutions.kasihkirim.ui.addresses.AddressesViewModel
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.board.BoardScreen
import com.ftechsolutions.kasihkirim.ui.home.HomeScreen
import com.ftechsolutions.kasihkirim.ui.orders.OrdersScreen
import com.ftechsolutions.kasihkirim.ui.profile.ProfileScreen
import com.ftechsolutions.kasihkirim.ui.send.SendScreen

private const val ADDRESSES_ROUTE = "addresses"

@Composable
fun AppNavHost(user: AuthUser, authViewModel: AuthViewModel, addressRepository: AddressRepository) {
    val nav: NavHostController = rememberNavController()
    val tabs = tabsFor(user.primaryRole)
    val entry by nav.currentBackStackEntryAsState()
    val current = entry?.destination?.route

    Scaffold(
        bottomBar = {
            NavigationBar {
                tabs.forEach { d ->
                    NavigationBarItem(
                        selected = current == d.route,
                        onClick = {
                            if (current != d.route) nav.navigate(d.route) {
                                popUpTo(tabs.first().route) { saveState = true }
                                launchSingleTop = true
                                restoreState = true
                            }
                        },
                        icon = {},
                        label = { Text(stringResource(d.labelRes)) },
                    )
                }
            }
        },
    ) { padding ->
        NavHost(
            navController = nav,
            startDestination = tabs.first().route,
            modifier = Modifier.padding(padding),
        ) {
            composable(Destination.HOME.route) { HomeScreen(user) }
            composable(Destination.PROFILE.route) {
                ProfileScreen(user, authViewModel, onOpenAddresses = { nav.navigate(ADDRESSES_ROUTE) })
            }
            composable(ADDRESSES_ROUTE) {
                val vm: AddressesViewModel = viewModel(factory = AddressesViewModel.Factory(addressRepository))
                AddressesScreen(vm, onBack = { nav.popBackStack() })
            }
            // Phase 1 renders honest placeholders. These are NOT mocks: they
            // claim nothing and call no backend. Phases 3-8 replace them.
            composable(Destination.SEND.route) { SendScreen() }
            composable(Destination.BOARD.route) { BoardScreen() }
            composable(Destination.ORDERS.route) { OrdersScreen() }
            composable(Destination.TRIPS.route) { PlaceholderScreen(Destination.TRIPS) }
            composable(Destination.EARNINGS.route) { PlaceholderScreen(Destination.EARNINGS) }
            composable(Destination.MUATAN_JUAL.route) { PlaceholderScreen(Destination.MUATAN_JUAL) }
            composable(Destination.SALES.route) { PlaceholderScreen(Destination.SALES) }
        }
    }
}
