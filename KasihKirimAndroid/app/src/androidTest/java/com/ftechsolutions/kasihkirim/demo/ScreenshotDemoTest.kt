package com.ftechsolutions.kasihkirim.demo

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.test.platform.app.InstrumentationRegistry
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Address
import com.ftechsolutions.kasihkirim.domain.model.AuthState
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.Delivery
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.KirimStatus
import com.ftechsolutions.kasihkirim.domain.model.KirimSummary
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.model.MuatanJualListing
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewTripDraft
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.model.UserRole
import com.ftechsolutions.kasihkirim.domain.model.DeliveryTracking
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.AuthRepository
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryRepository
import com.ftechsolutions.kasihkirim.domain.repository.DeliveryTrackingRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import com.ftechsolutions.kasihkirim.domain.repository.MuatanJualRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import com.ftechsolutions.kasihkirim.ui.auth.AuthScreen
import com.ftechsolutions.kasihkirim.ui.auth.AuthViewModel
import com.ftechsolutions.kasihkirim.ui.board.BoardScreen
import com.ftechsolutions.kasihkirim.ui.board.BoardViewModel
import com.ftechsolutions.kasihkirim.ui.deliveries.DeliveriesScreen
import com.ftechsolutions.kasihkirim.ui.deliveries.DeliveriesViewModel
import com.ftechsolutions.kasihkirim.ui.muatanjual.MuatanJualScreen
import com.ftechsolutions.kasihkirim.ui.muatanjual.MuatanJualViewModel
import com.ftechsolutions.kasihkirim.ui.orders.OrdersScreen
import com.ftechsolutions.kasihkirim.ui.orders.OrdersViewModel
import com.ftechsolutions.kasihkirim.ui.theme.KasihKirimTheme
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.io.FileOutputStream

// ── Sample data, not real Supabase rows: same fake-repository pattern as
//    AuthScreenTest, extended to every screen so a screenshot demo doesn't
//    need a seeded backend account to sign in with. ──────────────────────

private val kk = Community("c-kk", "Kota Kinabalu", "bandar", "Kota Kinabalu", "Sabah", nodeId = "node-kk")
private val menggatal = Community("c-menggatal", "Menggatal", "mukim", "Kota Kinabalu", "Sabah", nodeId = "node-menggatal")

private class FakeAuthRepository : AuthRepository {
    private val state = MutableStateFlow<AuthState>(AuthState.Unauthenticated)
    override val authState: StateFlow<AuthState> = state
    override suspend fun restoreSession() {}
    override suspend fun signUpWithEmail(email: String, password: String) = AppResult.Failure(AppError.InvalidCredentials)
    override suspend fun signInWithEmail(email: String, password: String) = AppResult.Failure(AppError.InvalidCredentials)
    override suspend fun signOut() = AppResult.Success(Unit)
}

private class FakeKirimRepository : KirimRepository {
    override suspend fun quoteKirim(draft: com.ftechsolutions.kasihkirim.domain.model.KirimDraft) =
        throw NotImplementedError("not exercised by these screens")
    override suspend fun createKirim(submission: com.ftechsolutions.kasihkirim.domain.model.KirimSubmission) =
        throw NotImplementedError("not exercised by these screens")

    override suspend fun listBoard() = AppResult.Success(
        listOf(
            KirimSummary("ks-1", "KJ-2609-101", KirimType.HANTAR, KirimStatus.POSTED,
                "Dokumen penting - salinan sijil kelahiran", 200, "node-kk", "node-menggatal",
                Sen.of(1500), null, null, "2026-09-09T02:10:00Z"),
            KirimSummary("ks-2", "KJ-2609-102", KirimType.BELI, KirimStatus.POSTED,
                "Ubat-ubatan dari Farmasi Menggatal", 500, "node-menggatal", "node-kk",
                Sen.of(3000), null, null, "2026-09-09T03:25:00Z"),
            KirimSummary("ks-3", "KJ-2609-103", KirimType.HANTAR, KirimStatus.POSTED,
                "Kotak kraf tangan untuk pameran", 1200, "node-kk", "node-menggatal",
                Sen.of(2500), null, null, "2026-09-09T04:05:00Z"),
        )
    )

    override suspend fun listMyKirims() = AppResult.Success(
        listOf(
            KirimSummary("ko-1", "KJ-2608-091", KirimType.BELI, KirimStatus.MATCHED,
                "Barangan runcit mingguan", 3000, "node-kk", "node-menggatal",
                Sen.of(4000), Sen.of(1800), Sen.of(180), "2026-09-08T09:00:00Z"),
            KirimSummary("ko-2", "KJ-2608-088", KirimType.HANTAR, KirimStatus.IN_TRANSIT,
                "Bungkusan pakaian kanak-kanak", 800, "node-menggatal", "node-kk",
                Sen.of(2000), Sen.of(1200), Sen.of(120), "2026-09-08T07:40:00Z"),
            KirimSummary("ko-3", "KJ-2607-055", KirimType.HANTAR, KirimStatus.COMPLETED,
                "Dokumen bank", 150, "node-kk", "node-menggatal",
                Sen.of(1000), Sen.of(900), Sen.of(90), "2026-09-05T11:15:00Z"),
        )
    )

    override suspend fun listMyInvites() = AppResult.Success(emptyList<com.ftechsolutions.kasihkirim.domain.model.CapacityInvite>())
    override suspend fun respondToInvite(inviteId: String) = AppResult.Success(Unit)
}

private class FakeTripRepository : TripRepository {
    override suspend fun listMyTrips() = AppResult.Success(
        listOf(
            Trip("t-1", TripStatus.ANNOUNCED, "node-kk", "node-menggatal", "2026-09-09T14:00:00Z",
                capacityWeightGrams = 50000, capacityVolumeCm3 = 200000, capacityParcels = 20,
                reservedWeightGrams = 5000, reservedVolumeCm3 = 10000, reservedParcels = 2),
        )
    )
    override suspend fun createTrip(draft: NewTripDraft) = throw NotImplementedError("not exercised by these screens")
    override suspend fun acceptOffer(tripId: String, kirimId: String) = AppResult.Success(Unit)
    override suspend fun sendCapacityInvite(tripId: String) = AppResult.Success(0)
}

private class FakeAddressRepository : AddressRepository {
    override suspend fun listAddresses() = AppResult.Success(
        listOf(
            Address("a-1", "Rumah", "Aisyah binti Karim", "+60198765432", kk, "Sebelah surau Kg Kepayan Baru", isDefault = true),
        )
    )
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError("not exercised by these screens")
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError("not exercised by these screens")
    override suspend fun setDefaultAddress(id: String) = AppResult.Success(Unit)
    override suspend fun deleteAddress(id: String) = AppResult.Success(Unit)
    override suspend fun searchCommunities(query: String) = AppResult.Success(listOf(kk, menggatal))
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String) =
        AppResult.Success<Serviceability>(Serviceability.Serviceable("Kota Kinabalu", "Kota Kinabalu", 12.4, 25, false, 1))
}

private const val DEMO_CARRIER_ID = "demo-carrier"

private class FakeDeliveryRepository : DeliveryRepository {
    override suspend fun listMyDeliveries() = AppResult.Success(
        listOf(
            Delivery("d-1", KirimStatus.AWAITING_PICKUP, KirimType.HANTAR, "KJ-2609-104",
                "Bungkusan pakaian kanak-kanak", Sen.ZERO, Sen.of(1200), null, "2026-09-09T05:00:00Z",
                carrierId = DEMO_CARRIER_ID, requesterId = "demo-customer"),
            Delivery("d-2", KirimStatus.OUT_FOR_DELIVERY, KirimType.BELI, "KJ-2609-098",
                "Barangan runcit dari kedai Menggatal", Sen.of(4500), Sen.of(900), null, "2026-09-09T01:30:00Z",
                carrierId = DEMO_CARRIER_ID, requesterId = "demo-customer"),
            Delivery("d-3", KirimStatus.DELIVERED, KirimType.HANTAR, "KJ-2608-071",
                "Peralatan sekolah", Sen.ZERO, Sen.of(1000), null, "2026-09-08T08:00:00Z",
                carrierId = DEMO_CARRIER_ID, requesterId = "demo-customer"),
        )
    )
    override suspend fun transition(deliveryId: String, event: String) = AppResult.Success(KirimStatus.PICKED_UP)
    override suspend fun submitProofAndTransition(
        deliveryId: String,
        leg: String,
        event: String,
        photoBytes: ByteArray,
    ) = AppResult.Success(KirimStatus.PICKED_UP)
    override suspend fun recordPurchase(deliveryId: String, actualGoodsSen: Long) =
        AppResult.Success(KirimStatus.AWAITING_PICKUP)
    override suspend fun openDispute(deliveryId: String, category: String, description: String) =
        AppResult.Success(Unit)
    override suspend fun listMyReviewedDeliveryIds() = AppResult.Success(emptySet<String>())
    override suspend fun submitReview(deliveryId: String, rating: Int, comment: String?) = AppResult.Success(Unit)
}

private class FakeDeliveryTrackingRepository : DeliveryTrackingRepository {
    override suspend fun updateMyLocation(
        deliveryId: String,
        lat: Double,
        lng: Double,
        headingDeg: Double?,
        speedKmh: Double?,
        accuracyM: Double?,
    ) = AppResult.Success(Unit)
    override suspend fun getTracking(deliveryId: String) = AppResult.Failure<DeliveryTracking>(AppError.Unexpected)
    override fun observeLocationChanges(deliveryId: String): Flow<Unit> = emptyFlow()
}

private class FakeMuatanJualRepository : MuatanJualRepository {
    override suspend fun listLots() = AppResult.Success(
        listOf(
            MuatanJualListing("mj-1", "carrier-1", "Sayur Segar Kampung Kepayan",
                listOf(HandlingFlag.PERISHABLE), "kg", Sen.of(500), 20.0, "2026-09-11T00:00:00Z"),
            MuatanJualListing("mj-2", "carrier-1", "Anyaman Tikar Tradisional",
                listOf(HandlingFlag.FRAGILE), "helai", Sen.of(4500), 5.0, null),
            MuatanJualListing("mj-3", "carrier-2", "Ikan Kering Hasil Laut Sabah",
                listOf(HandlingFlag.PERISHABLE, HandlingFlag.COLD_CHAIN), "kg", Sen.of(3000), 15.0, "2026-09-15T00:00:00Z"),
        )
    )
}

/**
 * One-off screenshot capture, not a correctness test: renders each screen
 * against the fakes above (never real Supabase) with realistic sample data,
 * and dumps a PNG per screen under externalFilesDir so CI can pull them as
 * demo artifacts without a seeded backend account to sign in with.
 */
class ScreenshotDemoTest {

    @get:Rule val composeRule = createComposeRule()

    private fun capture(name: String) {
        composeRule.waitForIdle()
        val bitmap = composeRule.onRoot().captureToImage().asAndroidBitmap()
        val dir = File(
            InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),
            "demo-screenshots",
        )
        dir.mkdirs()
        FileOutputStream(File(dir, "$name.png")).use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
    }

    @Test fun auth() {
        composeRule.setContent { KasihKirimTheme { AuthScreen(AuthViewModel(FakeAuthRepository())) } }
        capture("01-auth")
    }

    @Test fun board() {
        composeRule.setContent {
            KasihKirimTheme {
                BoardScreen(
                    BoardViewModel(FakeKirimRepository(), FakeTripRepository(), FakeAddressRepository(), isCarrier = true),
                    isCarrier = true,
                )
            }
        }
        capture("02-board")
    }

    @Test fun orders() {
        composeRule.setContent {
            KasihKirimTheme {
                OrdersScreen(OrdersViewModel(FakeKirimRepository(), FakeAddressRepository()), onOpenDeliveries = {})
            }
        }
        capture("03-orders")
    }

    @Test fun deliveries() {
        composeRule.setContent {
            KasihKirimTheme {
                DeliveriesScreen(
                    DeliveriesViewModel(FakeDeliveryRepository(), FakeDeliveryTrackingRepository()),
                    currentUserId = DEMO_CARRIER_ID,
                    myCarrierId = DEMO_CARRIER_ID,
                    roles = setOf(UserRole.CARRIER),
                    onBack = {},
                    onOpenTracking = {},
                )
            }
        }
        capture("04-deliveries")
    }

    @Test fun muatanJual() {
        composeRule.setContent { KasihKirimTheme { MuatanJualScreen(MuatanJualViewModel(FakeMuatanJualRepository())) } }
        capture("05-muatan-jual")
    }
}
