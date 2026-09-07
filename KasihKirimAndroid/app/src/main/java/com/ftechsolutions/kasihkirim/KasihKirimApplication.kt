package com.ftechsolutions.kasihkirim

import android.app.Application
import com.ftechsolutions.kasihkirim.data.repository.AddressRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.AuthRepositoryImpl
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository

/**
 * Manual dependency container. Hilt is not used in Phase 1: a single
 * dependency does not justify an annotation processor, and §9 asks for the
 * simplest structure that works. Introduce DI when the graph earns it.
 */
class KasihKirimApplication : Application() {
    val authRepository: AuthRepository by lazy { AuthRepositoryImpl() }
    val addressRepository: AddressRepository by lazy { AddressRepositoryImpl() }
}
