package com.ftechsolutions.kasihkirim

import android.app.Application
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.repository.AddressRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.AuthRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.AdminRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.BadgeRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.BuyRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.CarrierRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.DeliveryRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.EarningsRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.KirimRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.MuatanJualRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.PromotionRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.SellerRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.TripRepositoryImpl
import com.ftechsolutions.kasihkirim.data.repository.VehicleRepositoryImpl
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository
import com.ftechsolutions.kasihkirim.domain.repository.AdminRepository
import com.ftechsolutions.kasihkirim.domain.repository.BadgeRepository
import com.ftechsolutions.kasihkirim.domain.repository.BuyRepository
import com.ftechsolutions.kasihkirim.domain.repository.CarrierRepository
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import com.ftechsolutions.kasihkirim.domain.repository.PromotionRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import com.ftechsolutions.kasihkirim.domain.repository.VehicleRepository

/**
 * Manual dependency container. Hilt is not used in Phase 1: a single
 * dependency does not justify an annotation processor, and §9 asks for the
 * simplest structure that works. Introduce DI when the graph earns it.
 */
class KasihKirimApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        SupabaseClientProvider.init(this)
    }

    val authRepository: AuthRepository by lazy { AuthRepositoryImpl() }
    val addressRepository: AddressRepository by lazy { AddressRepositoryImpl() }
    val kirimRepository: KirimRepository by lazy { KirimRepositoryImpl() }
    val earningsRepository: EarningsRepository by lazy { EarningsRepositoryImpl() }
    val vehicleRepository: VehicleRepository by lazy { VehicleRepositoryImpl() }
    val tripRepository: TripRepository by lazy { TripRepositoryImpl() }
    val deliveryRepository: DeliveryRepository by lazy { DeliveryRepositoryImpl() }
    val muatanJualRepository: MuatanJualRepository by lazy { MuatanJualRepositoryImpl() }
    val sellerRepository: SellerRepository by lazy { SellerRepositoryImpl() }
    val carrierRepository: CarrierRepository by lazy { CarrierRepositoryImpl() }
    val buyRepository: BuyRepository by lazy { BuyRepositoryImpl() }
    val badgeRepository: BadgeRepository by lazy { BadgeRepositoryImpl() }
    val adminRepository: AdminRepository by lazy { AdminRepositoryImpl() }
    val promotionRepository: PromotionRepository by lazy { PromotionRepositoryImpl() }
}
