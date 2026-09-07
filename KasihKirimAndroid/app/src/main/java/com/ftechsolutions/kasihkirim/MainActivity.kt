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
        val repo = (application as KasihKirimApplication).authRepository
        setContent {
            KasihKirimTheme {
                val vm: AuthViewModel = viewModel(factory = AuthViewModel.Factory(repo))
                App(vm)
            }
        }
    }
}
