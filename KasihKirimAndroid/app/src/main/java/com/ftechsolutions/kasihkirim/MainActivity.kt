package com.ftechsolutions.kasihkirim

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ftechsolutions.kasihkirim.ui.App
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.theme.KasihKirimTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val app = application as KasihKirimApplication
        setContent {
            KasihKirimTheme {
                val vm: AuthViewModel = viewModel(factory = AuthViewModel.Factory(app.authRepository))
                App(
                    vm,
                    app.addressRepository,
                    app.kirimRepository,
                    app.earningsRepository,
                    app.vehicleRepository,
                    app.tripRepository,
                    app.deliveryRepository,
                    app.deliveryTrackingRepository,
                    app.muatanJualRepository,
                    app.sellerRepository,
                    app.carrierRepository,
                    app.carrierLotRepository,
                    app.buyRepository,
                    app.badgeRepository,
                    app.adminRepository,
                    app.promotionRepository,
                    app.dealsRepository,
                )
            }
        }
    }
}
