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
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.ui.addresses.AddressesScreen
import com.ftechsolutions.kasihkirim.ui.addresses.AddressesViewModel
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.board.BoardScreen
import com.ftechsolutions.kasihkirim.ui.home.HomeScreen
import com.ftechsolutions.kasihkirim.ui.orders.OrdersScreen
import com.ftechsolutions.kasihkirim.ui.profile.ProfileScreen
import com.ftechsolutions.kasihkirim.ui.send.KirimQuoteViewModel
import com.ftechsolutions.kasihkirim.ui.send.SendScreen
import com.ftechsolutions.kasihkirim.ui.serviceability.ServiceabilityScreen
import com.ftechsolutions.kasihkirim.ui.serviceability.ServiceabilityViewModel

private const val ADDRESSES_ROUTE = "addresses"
private const val SERVICEABILITY_ROUTE = "serviceability"

@Composable
fun AppNavHost(
    user: AuthUser,
    authViewModel: AuthViewModel,
    addressRepository: AddressRepository,
    kirimRepository: KirimRepository,
) {
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
                ProfileScreen(
                    user,
                    authViewModel,
                    onOpenAddresses = { nav.navigate(ADDRESSES_ROUTE) },
                    onOpenServiceability = { nav.navigate(SERVICEABILITY_ROUTE) },
                )
            }
            composable(ADDRESSES_ROUTE) {
                val vm: AddressesViewModel = viewModel(factory = AddressesViewModel.Factory(addressRepository))
                AddressesScreen(vm, onBack = { nav.popBackStack() })
            }
            composable(SERVICEABILITY_ROUTE) {
                val vm: ServiceabilityViewModel = viewModel(factory = ServiceabilityViewModel.Factory(addressRepository))
                ServiceabilityScreen(vm, onBack = { nav.popBackStack() })
            }
            composable(Destination.SEND.route) {
                val vm: KirimQuoteViewModel =
                    viewModel(factory = KirimQuoteViewModel.Factory(kirimRepository, addressRepository))
                SendScreen(vm)
            }
            // Phase 1 renders honest placeholders. These are NOT mocks: they
            // claim nothing and call no backend. Phases 4-8 replace them.
            composable(Destination.BOARD.route) { BoardScreen() }
            composable(Destination.ORDERS.route) { OrdersScreen() }
            composable(Destination.TRIPS.route) { PlaceholderScreen(Destination.TRIPS) }
            composable(Destination.EARNINGS.route) { PlaceholderScreen(Destination.EARNINGS) }
            composable(Destination.MUATAN_JUAL.route) { PlaceholderScreen(Destination.MUATAN_JUAL) }
            composable(Destination.SALES.route) { PlaceholderScreen(Destination.SALES) }
        }
    }
}
