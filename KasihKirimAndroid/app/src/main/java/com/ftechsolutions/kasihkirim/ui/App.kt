package com.ftechsolutions.kasihkirim.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.AdminRepository
import com.ftechsolutions.kasihkirim.domain.repository.BadgeRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import com.ftechsolutions.kasihkirim.domain.repository.CarrierRepository
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository
import com.ftechsolutions.kasihkirim.ui.auth.AuthScreen
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.navigation.AppNavHost

/**
 * The four auth states drive the whole shell. Initializing is distinct from
 * Unauthenticated on purpose: without it the app flashes a sign-in screen for
 * a moment on every cold start while the session is restored from Keystore.
 */
@Composable
fun App(
    vm: AuthViewModel,
    addressRepository: AddressRepository,
    kirimRepository: KirimRepository,
    earningsRepository: EarningsRepository,
    vehicleRepository: VehicleRepository,
    tripRepository: TripRepository,
    deliveryRepository: DeliveryRepository,
    muatanJualRepository: MuatanJualRepository,
    sellerRepository: SellerRepository,
    carrierRepository: CarrierRepository,
    buyRepository: BuyRepository,
    badgeRepository: BadgeRepository,
    adminRepository: AdminRepository,
) {
    val state by vm.authState.collectAsStateWithLifecycle()

    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        when (val s = state) {
            AuthState.Initializing -> Centered {
                CircularProgressIndicator()
                Spacer(Modifier.height(12.dp))
                Text(stringResource(R.string.auth_checking))
            }
            AuthState.Unauthenticated -> AuthScreen(vm)
            is AuthState.Authenticated -> AppNavHost(
                s.user, vm, addressRepository, kirimRepository, earningsRepository,
                vehicleRepository, tripRepository, deliveryRepository, muatanJualRepository,
                sellerRepository, carrierRepository, buyRepository, badgeRepository, adminRepository,
            )
            is AuthState.Error -> Centered {
                Text(stringResource(s.error.messageRes()),
                    color = MaterialTheme.colorScheme.error)
            }
        }
    }
}

@Composable
private fun Centered(content: @Composable ColumnScope.() -> Unit) = Column(
    modifier = Modifier.fillMaxSize().padding(24.dp),
    verticalArrangement = Arrangement.Center,
    horizontalAlignment = Alignment.CenterHorizontally,
    content = content,
)
