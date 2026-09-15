package com.ftechsolutions.kasihkirim.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavHostController
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.ftechsolutions.kasihkirim.domain.model.AuthUser
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.AdminRepository
import com.ftechsolutions.kasihkirim.domain.repository.BadgeRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import com.ftechsolutions.kasihkirim.domain.repository.CarrierRepository
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryTrackingRepository
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import com.ftechsolutions.kasihkirim.domain.repository.PromotionRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import com.ftechsolutions.kasihkirim.ui.addresses.AddressesScreen
import com.ftechsolutions.kasihkirim.ui.addresses.AddressesViewModel
import com.ftechsolutions.kasihkirim.ui.admin.AdminScreen
import com.ftechsolutions.kasihkirim.ui.admin.AdminViewModel
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.board.BoardScreen
import com.ftechsolutions.kasihkirim.ui.board.BoardViewModel
import com.ftechsolutions.kasihkirim.ui.buy.BuyOrdersScreen
import com.ftechsolutions.kasihkirim.ui.buy.BuyOrdersViewModel
import com.ftechsolutions.kasihkirim.ui.buy.BuyScreen
import com.ftechsolutions.kasihkirim.ui.buy.BuyViewModel
import com.ftechsolutions.kasihkirim.ui.carrier.CarrierApplicationScreen
import com.ftechsolutions.kasihkirim.ui.carrier.CarrierApplicationViewModel
import com.ftechsolutions.kasihkirim.ui.deliveries.DeliveriesScreen
import com.ftechsolutions.kasihkirim.ui.deliveries.DeliveriesViewModel
import com.ftechsolutions.kasihkirim.ui.deliveries.DeliveryTrackingScreen
import com.ftechsolutions.kasihkirim.ui.deliveries.DeliveryTrackingViewModel
import com.ftechsolutions.kasihkirim.ui.earnings.EarningsScreen
import com.ftechsolutions.kasihkirim.ui.earnings.EarningsViewModel
import com.ftechsolutions.kasihkirim.ui.home.HomeScreen
import com.ftechsolutions.kasihkirim.ui.muatanjual.MuatanJualScreen
import com.ftechsolutions.kasihkirim.ui.muatanjual.MuatanJualViewModel
import com.ftechsolutions.kasihkirim.ui.orders.OrdersScreen
import com.ftechsolutions.kasihkirim.ui.orders.OrdersViewModel
import com.ftechsolutions.kasihkirim.ui.profile.ProfileScreen
import com.ftechsolutions.kasihkirim.ui.profile.ProfileViewModel
import com.ftechsolutions.kasihkirim.ui.promotions.PromotionsScreen
import com.ftechsolutions.kasihkirim.ui.promotions.PromotionsViewModel
import com.ftechsolutions.kasihkirim.ui.sales.SalesScreen
import com.ftechsolutions.kasihkirim.ui.sales.SalesViewModel
import com.ftechsolutions.kasihkirim.ui.send.KirimQuoteViewModel
import com.ftechsolutions.kasihkirim.ui.send.SendScreen
import com.ftechsolutions.kasihkirim.ui.serviceability.ServiceabilityScreen
import com.ftechsolutions.kasihkirim.ui.serviceability.ServiceabilityViewModel
import com.ftechsolutions.kasihkirim.ui.trips.TripsScreen
import com.ftechsolutions.kasihkirim.ui.trips.TripsViewModel
import com.ftechsolutions.kasihkirim.ui.vehicles.VehiclesScreen
import com.ftechsolutions.kasihkirim.ui.vehicles.VehiclesViewModel

private const val ADDRESSES_ROUTE = "addresses"
private const val SERVICEABILITY_ROUTE = "serviceability"
private const val VEHICLES_ROUTE = "vehicles"
private const val DELIVERIES_ROUTE = "deliveries"
private const val DELIVERY_TRACKING_ROUTE = "delivery_tracking"
private const val BUY_ROUTE = "buy"
private const val BUY_ORDERS_ROUTE = "buy_orders"
private const val CARRIER_APPLICATION_ROUTE = "carrier_application"
private const val PROMOTIONS_ROUTE = "promotions"

@Composable
fun AppNavHost(
    user: AuthUser,
    authViewModel: AuthViewModel,
    addressRepository: AddressRepository,
    kirimRepository: KirimRepository,
    earningsRepository: EarningsRepository,
    vehicleRepository: VehicleRepository,
    tripRepository: TripRepository,
    deliveryRepository: DeliveryRepository,
    deliveryTrackingRepository: DeliveryTrackingRepository,
    muatanJualRepository: MuatanJualRepository,
    sellerRepository: SellerRepository,
    carrierRepository: CarrierRepository,
    buyRepository: BuyRepository,
    badgeRepository: BadgeRepository,
    adminRepository: AdminRepository,
    promotionRepository: PromotionRepository,
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
                        icon = { Icon(d.icon, contentDescription = null) },
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
            composable(Destination.HOME.route) {
                HomeScreen(user, onOpenBuy = { nav.navigate(BUY_ROUTE) })
            }
            composable(Destination.PROFILE.route) {
                val profileVm: ProfileViewModel = viewModel(factory = ProfileViewModel.Factory(badgeRepository))
                ProfileScreen(
                    user,
                    authViewModel,
                    profileVm,
                    onOpenAddresses = { nav.navigate(ADDRESSES_ROUTE) },
                    onOpenServiceability = { nav.navigate(SERVICEABILITY_ROUTE) },
                    onOpenSales = { nav.navigate(Destination.SALES.route) },
                    onOpenCarrierApplication = { nav.navigate(CARRIER_APPLICATION_ROUTE) },
                    onOpenPromotions = { nav.navigate(PROMOTIONS_ROUTE) },
                )
            }
            composable(CARRIER_APPLICATION_ROUTE) {
                val vm: CarrierApplicationViewModel = viewModel(
                    factory = CarrierApplicationViewModel.Factory(carrierRepository, addressRepository),
                )
                CarrierApplicationScreen(vm, onBack = { nav.popBackStack() })
            }
            composable(PROMOTIONS_ROUTE) {
                val vm: PromotionsViewModel = viewModel(
                    factory = PromotionsViewModel.Factory(promotionRepository, earningsRepository),
                )
                PromotionsScreen(vm, onBack = { nav.popBackStack() })
            }
            // Jualan Phase B (0020_jualan_checkout_and_growth.sql): browse
            // active products across all sellers, cart, checkout. Reached
            // from Home rather than a bottom tab -- the tab row is already
            // full per role (Destinations.kt), same reasoning as
            // ADDRESSES_ROUTE/VEHICLES_ROUTE living off Profile/Trips.
            composable(BUY_ROUTE) {
                val vm: BuyViewModel = viewModel(
                    factory = BuyViewModel.Factory(buyRepository, addressRepository, promotionRepository),
                )
                BuyScreen(vm, onBack = { nav.popBackStack() }, onOpenOrders = { nav.navigate(BUY_ORDERS_ROUTE) })
            }
            composable(BUY_ORDERS_ROUTE) {
                val vm: BuyOrdersViewModel = viewModel(factory = BuyOrdersViewModel.Factory(buyRepository))
                BuyOrdersScreen(vm, onBack = { nav.popBackStack() })
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
            composable(Destination.EARNINGS.route) {
                val vm: EarningsViewModel = viewModel(factory = EarningsViewModel.Factory(earningsRepository))
                EarningsScreen(vm)
            }
            composable(Destination.TRIPS.route) {
                val vm: TripsViewModel =
                    viewModel(factory = TripsViewModel.Factory(tripRepository, vehicleRepository, addressRepository))
                TripsScreen(
                    vm,
                    onOpenVehicles = { nav.navigate(VEHICLES_ROUTE) },
                    onOpenDeliveries = { nav.navigate(DELIVERIES_ROUTE) },
                )
            }
            composable(VEHICLES_ROUTE) {
                val vm: VehiclesViewModel = viewModel(factory = VehiclesViewModel.Factory(vehicleRepository))
                VehiclesScreen(vm, onBack = { nav.popBackStack() })
            }
            composable(DELIVERIES_ROUTE) {
                val vm: DeliveriesViewModel = viewModel(
                    factory = DeliveriesViewModel.Factory(deliveryRepository, deliveryTrackingRepository),
                )
                DeliveriesScreen(
                    vm,
                    currentUserId = user.id,
                    myCarrierId = user.carrierId,
                    roles = user.roles,
                    onBack = { nav.popBackStack() },
                    onOpenTracking = { deliveryId -> nav.navigate("$DELIVERY_TRACKING_ROUTE/$deliveryId") },
                )
            }
            composable(
                "$DELIVERY_TRACKING_ROUTE/{deliveryId}",
                arguments = listOf(navArgument("deliveryId") { type = NavType.StringType }),
            ) { backStackEntry ->
                val deliveryId = backStackEntry.arguments?.getString("deliveryId")
                if (deliveryId != null) {
                    val vm: DeliveryTrackingViewModel = viewModel(
                        factory = DeliveryTrackingViewModel.Factory(deliveryTrackingRepository, deliveryId),
                    )
                    DeliveryTrackingScreen(vm, onBack = { nav.popBackStack() })
                }
            }
            composable(Destination.BOARD.route) {
                val vm: BoardViewModel = viewModel(
                    factory = BoardViewModel.Factory(
                        kirimRepository, tripRepository, addressRepository, isCarrier = user.carrierId != null,
                    ),
                )
                BoardScreen(vm, isCarrier = user.carrierId != null)
            }
            composable(Destination.ORDERS.route) {
                val vm: OrdersViewModel = viewModel(factory = OrdersViewModel.Factory(kirimRepository, addressRepository))
                OrdersScreen(vm, onOpenDeliveries = { nav.navigate(DELIVERIES_ROUTE) })
            }
            // Review queues (0023_admin_review_surface.sql). The tab is only
            // in an admin's tab set, but the route is registered for everyone
            // -- hiding it is convenience, and every read and write behind it
            // is gated by RLS and each RPC's own is_admin() check.
            composable(Destination.ADMIN.route) {
                val vm: AdminViewModel = viewModel(factory = AdminViewModel.Factory(adminRepository))
                AdminScreen(vm)
            }
            composable(Destination.MUATAN_JUAL.route) {
                val vm: MuatanJualViewModel = viewModel(factory = MuatanJualViewModel.Factory(muatanJualRepository))
                MuatanJualScreen(vm)
            }
            // Jualan Phase A (0016/0017_seller_onboarding.sql): seller
            // application + product catalog. Reachable from the SALES tab
            // (sellers only, per tabsFor) and from Profile's "Jadi Penjual"
            // row (everyone else, so there's actually a way in before the
            // role is granted) -- same route either way, the screen itself
            // renders the right state (apply / pending / catalog). Separate
            // from Phase 8's browse-only Muatan Jual screen above, which is
            // a different feature (carrier-as-trader, ADDENDUM-COMMERCE.md),
            // not this one.
            composable(Destination.SALES.route) {
                val vm: SalesViewModel = viewModel(
                    factory = SalesViewModel.Factory(sellerRepository, addressRepository, earningsRepository),
                )
                SalesScreen(vm, onBack = { nav.popBackStack() })
            }
        }
    }
}
