package com.ftechsolutions.kasihkirim.ui.muatanjual

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierLot
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.NewLot
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.Trip
import com.ftechsolutions.kasihkirim.domain.model.TripStatus
import com.ftechsolutions.kasihkirim.domain.repository.CarrierLotRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import com.ftechsolutions.kasihkirim.domain.repository.TripRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class CarrierLotsUiState(
    /** null means the caller has never applied as a seller at all -- the
     *  screen offers a way to Sales' own apply flow rather than duplicating
     *  its community-picker form here. */
    val seller: Seller? = null,
    val lots: List<CarrierLot> = emptyList(),
    /** Trips this carrier could attach a DRAFT lot to -- filtered to the
     *  same statuses rpc_attach_lot_to_trip itself accepts. */
    val attachableTrips: List<Trip> = emptyList(),
    val isLoading: Boolean = true,
    val error: AppError? = null,
    val showCreateForm: Boolean = false,
    val createTitle: String = "",
    val createCategory: KirimCategory = KirimCategory.SAYUR,
    val createQtyText: String = "",
    val createUnit: String = "kg",
    val createCostBasisRinggitText: String = "",
    val createPriceRinggitText: String = "",
    val createHandlingFlags: Set<HandlingFlag> = emptySet(),
    val createReceiptPath: String? = null,
    val isUploadingReceipt: Boolean = false,
    val isSubmittingCreate: Boolean = false,
    val isAcceptingTerms: Boolean = false,
    /** Non-null while the trip picker for this DRAFT lot is open. */
    val attachingLotId: String? = null,
    /** The lot currently mid attach/withdraw -- disables only its own row. */
    val busyLotId: String? = null,
)

class CarrierLotsViewModel(
    private val lotRepo: CarrierLotRepository,
    private val sellerRepo: SellerRepository,
    private val tripRepo: TripRepository,
    private val carrierId: String,
) : ViewModel() {

    private val _state = MutableStateFlow(CarrierLotsUiState())
    val state: StateFlow<CarrierLotsUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            val sellerResult = sellerRepo.getMySellerApplication()
            val seller = (sellerResult as? AppResult.Success)?.data
            val lots = if (seller != null) lotRepo.listMyLots(carrierId) else AppResult.Success(emptyList())
            val trips = tripRepo.listMyTrips()
            _state.update {
                it.copy(
                    isLoading = false,
                    seller = seller,
                    lots = (lots as? AppResult.Success)?.data ?: it.lots,
                    attachableTrips = (trips as? AppResult.Success)?.data
                        ?.filter { t -> t.status in ATTACHABLE_TRIP_STATUSES }
                        ?: it.attachableTrips,
                    error = listOf(sellerResult, lots, trips)
                        .filterIsInstance<AppResult.Failure>()
                        .firstOrNull()?.error,
                )
            }
        }
    }

    fun acceptTerms() {
        viewModelScope.launch {
            _state.update { it.copy(isAcceptingTerms = true, error = null) }
            when (val result = sellerRepo.acceptMuatanJualTerms()) {
                is AppResult.Success -> { _state.update { it.copy(isAcceptingTerms = false) }; load() }
                is AppResult.Failure -> _state.update { it.copy(isAcceptingTerms = false, error = result.error) }
            }
        }
    }

    fun openCreateForm() = _state.update {
        it.copy(
            showCreateForm = true, createTitle = "", createCategory = KirimCategory.SAYUR,
            createQtyText = "", createUnit = "kg", createCostBasisRinggitText = "",
            createPriceRinggitText = "", createHandlingFlags = emptySet(), createReceiptPath = null,
            error = null,
        )
    }
    fun closeCreateForm() = _state.update { it.copy(showCreateForm = false) }

    fun onCreateTitleChange(text: String) = _state.update { it.copy(createTitle = text) }
    fun onCreateCategoryChange(category: KirimCategory) = _state.update { it.copy(createCategory = category) }
    fun onCreateQtyChange(text: String) = _state.update { it.copy(createQtyText = text) }
    fun onCreateUnitChange(text: String) = _state.update { it.copy(createUnit = text) }
    fun onCreateCostBasisChange(text: String) = _state.update { it.copy(createCostBasisRinggitText = text) }
    fun onCreatePriceChange(text: String) = _state.update { it.copy(createPriceRinggitText = text) }
    fun onToggleHandlingFlag(flag: HandlingFlag) = _state.update {
        it.copy(createHandlingFlags = if (flag in it.createHandlingFlags) it.createHandlingFlags - flag else it.createHandlingFlags + flag)
    }

    /** A receipt photo was captured for the open create-lot form. */
    fun captureReceipt(photoBytes: ByteArray) {
        viewModelScope.launch {
            _state.update { it.copy(isUploadingReceipt = true, error = null) }
            when (val result = lotRepo.uploadLotReceipt(photoBytes)) {
                is AppResult.Success ->
                    _state.update { it.copy(isUploadingReceipt = false, createReceiptPath = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isUploadingReceipt = false, error = result.error) }
            }
        }
    }

    fun submitCreate() {
        val s = _state.value
        val qty = s.createQtyText.toDoubleOrNull()?.takeIf { it > 0 } ?: return
        val costBasisSen = s.createCostBasisRinggitText.toDoubleOrNull()?.let { (it * 100).toLong() } ?: return
        val priceSen = s.createPriceRinggitText.toDoubleOrNull()?.takeIf { it > 0 }?.let { (it * 100).toLong() } ?: return
        val receiptPath = s.createReceiptPath ?: return
        viewModelScope.launch {
            _state.update { it.copy(isSubmittingCreate = true, error = null) }
            val draft = NewLot(
                title = s.createTitle.trim(),
                categorySlug = s.createCategory.slug,
                qtyTotal = qty,
                costBasisSen = costBasisSen,
                costReceiptPath = receiptPath,
                pricePerUnitSen = priceSen,
                unit = s.createUnit.trim().ifEmpty { "kg" },
                handlingFlags = s.createHandlingFlags.toList(),
                photoPaths = emptyList(),
            )
            when (val result = lotRepo.createLot(draft)) {
                is AppResult.Success -> { _state.update { it.copy(isSubmittingCreate = false, showCreateForm = false) }; load() }
                is AppResult.Failure -> _state.update { it.copy(isSubmittingCreate = false, error = result.error) }
            }
        }
    }

    fun requestAttach(lotId: String) = _state.update { it.copy(attachingLotId = lotId, error = null) }
    fun cancelAttach() = _state.update { it.copy(attachingLotId = null) }

    fun attachToTrip(tripId: String) {
        val lotId = _state.value.attachingLotId ?: return
        viewModelScope.launch {
            _state.update { it.copy(busyLotId = lotId, attachingLotId = null, error = null) }
            when (val result = lotRepo.attachLotToTrip(lotId, tripId)) {
                is AppResult.Success -> { _state.update { it.copy(busyLotId = null) }; load() }
                is AppResult.Failure -> _state.update { it.copy(busyLotId = null, error = result.error) }
            }
        }
    }

    fun withdrawLot(lotId: String) {
        viewModelScope.launch {
            _state.update { it.copy(busyLotId = lotId, error = null) }
            when (val result = lotRepo.withdrawLot(lotId)) {
                is AppResult.Success -> { _state.update { it.copy(busyLotId = null) }; load() }
                is AppResult.Failure -> _state.update { it.copy(busyLotId = null, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val lotRepo: CarrierLotRepository,
        private val sellerRepo: SellerRepository,
        private val tripRepo: TripRepository,
        private val carrierId: String,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            CarrierLotsViewModel(lotRepo, sellerRepo, tripRepo, carrierId) as T
    }
}

private val ATTACHABLE_TRIP_STATUSES = setOf(TripStatus.DRAFT, TripStatus.ANNOUNCED, TripStatus.BOARDING)
