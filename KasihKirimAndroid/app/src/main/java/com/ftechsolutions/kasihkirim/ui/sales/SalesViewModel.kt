package com.ftechsolutions.kasihkirim.ui.sales

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.Earnings
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.Inventory
import com.ftechsolutions.kasihkirim.domain.model.InventoryMovement
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerDashboard
import com.ftechsolutions.kasihkirim.domain.model.SellerOrder
import com.ftechsolutions.kasihkirim.domain.model.SellerOrderStatus
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.EarningsRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** The seller application form -- rpc_apply_seller's params. */
data class SellerApplicationFormState(
    val businessName: String = "",
    val ssmRegNo: String = "",
    val communityQuery: String = "",
    val selectedCommunity: Community? = null,
    val communityResults: List<Community> = emptyList(),
) {
    val canSubmit: Boolean get() = businessName.trim().length >= 3 && selectedCommunity != null
}

/** Presentation-only bounds mirroring public.products' CHECK constraints
 *  (0016_seller_onboarding.sql), same shape as VehicleFormState. */
data class ProductFormState(
    val editingId: String? = null,
    val title: String = "",
    val description: String = "",
    val category: KirimCategory? = null,
    val priceRinggit: String = "",
    val unit: String = "kg",
    val weightGrams: String = "",
    val minOrderQty: String = "1",
    val handlingFlags: Set<HandlingFlag> = emptySet(),
) {
    val isEditing: Boolean get() = editingId != null

    val canSubmit: Boolean
        get() = title.trim().length >= 3 && category != null &&
            (priceRinggit.toDoubleOrNull() ?: 0.0) > 0.0 &&
            (weightGrams.toIntOrNull() ?: 0) > 0

    fun toDraftOrNull(): NewProduct? {
        val cat = category ?: return null
        val priceSen = priceRinggit.toDoubleOrNull()?.takeIf { it > 0 }?.let { (it * 100).toLong() } ?: return null
        val weight = weightGrams.toIntOrNull()?.takeIf { it > 0 } ?: return null
        val minQty = minOrderQty.toIntOrNull()?.takeIf { it > 0 } ?: 1
        return NewProduct(
            title = title.trim(),
            description = description.trim().takeIf { it.isNotEmpty() },
            category = cat,
            priceSen = priceSen,
            unit = unit.trim().takeIf { it.isNotEmpty() } ?: "kg",
            weightGrams = weight,
            volumeCm3 = 8000,
            handlingFlags = handlingFlags.toList(),
            minOrderQty = minQty,
        )
    }
}

enum class SalesTab { DASHBOARD, PRODUCTS, ORDERS }

/** rpc_set_stock/rpc_adjust_stock's own inputs, entered as text the same way
 *  ProductFormState's price/weight fields are -- validated before either
 *  RPC is ever called, but the RPC's own refusals (STOCK_NEGATIVE,
 *  STOCK_BELOW_RESERVED, STOCK_DELTA_ZERO) remain the actual authority. */
data class StockDialogState(
    val productId: String,
    /** The last server-confirmed figures -- read-only display (reserved is
     *  never editable client-side at all). Refreshed after every successful
     *  setStock/adjustStock call, from that same call's own response. */
    val current: Inventory?,
    val onHandInput: String,
    val safetyStockInput: String,
    val adjustDeltaInput: String = "",
    val movements: List<InventoryMovement> = emptyList(),
    val isLoadingMovements: Boolean = false,
    val isSaving: Boolean = false,
) {
    val onHandOrNull: Int? get() = onHandInput.toIntOrNull()?.takeIf { it >= 0 }
    val safetyStockOrNull: Int? get() = safetyStockInput.toIntOrNull()?.takeIf { it >= 0 }
    val adjustDeltaOrNull: Int? get() = adjustDeltaInput.toIntOrNull()?.takeIf { it != 0 }
}

data class SalesUiState(
    val isLoading: Boolean = true,
    /** null once loaded means "never applied" -- see the empty-state screen. */
    val seller: Seller? = null,
    val products: List<Product> = emptyList(),
    val selectedTab: SalesTab = SalesTab.DASHBOARD,
    val orders: List<SellerOrder> = emptyList(),
    val isLoadingOrders: Boolean = false,
    val error: AppError? = null,
    val isSubmittingApplication: Boolean = false,
    val applicationForm: SellerApplicationFormState = SellerApplicationFormState(),
    val isSubmittingProduct: Boolean = false,
    /** null means the add/edit product sheet is closed. */
    val productForm: ProductFormState? = null,
    val transitioningProductId: String? = null,
    val uploadingImageForProductId: String? = null,
    // ── Dashboard (0035) ──────────────────────────────────────────────────
    val dashboard: SellerDashboard? = null,
    val isLoadingDashboard: Boolean = false,
    val earnings: Earnings? = null,
    // ── Stock (0025) ──────────────────────────────────────────────────────
    /** null means the stock sheet for a product is closed. */
    val stockDialog: StockDialogState? = null,
    // ── Archive ───────────────────────────────────────────────────────────
    val archiveConfirmProductId: String? = null,
    val isArchivingProduct: Boolean = false,
    // ── Order detail + dispute (0035, 0030) ──────────────────────────────
    val selectedOrder: SellerOrder? = null,
    val selectedOrderStatus: SellerOrderStatus? = null,
    val isLoadingOrderStatus: Boolean = false,
    val showDisputeConfirm: Boolean = false,
    val isFilingDispute: Boolean = false,
    val disputeSubmitted: Boolean = false,
)

class SalesViewModel(
    private val sellerRepo: SellerRepository,
    private val addressRepo: AddressRepository,
    private val earningsRepo: EarningsRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(SalesUiState())
    val state: StateFlow<SalesUiState> = _state.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            _state.update { it.copy(isLoading = true, error = null) }
            when (val result = sellerRepo.getMySellerApplication()) {
                is AppResult.Success -> {
                    val seller = result.data
                    _state.update { it.copy(seller = seller, isLoading = seller != null) }
                    if (seller != null) {
                        loadProducts(seller.id)
                        loadOrders(seller.id)
                        loadDashboard()
                    } else {
                        _state.update { it.copy(isLoading = false) }
                    }
                }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
            }
        }
    }

    // ── Dashboard ─────────────────────────────────────────────────────────

    fun loadDashboard() {
        viewModelScope.launch {
            _state.update { it.copy(isLoadingDashboard = true) }
            val dashboardResult = sellerRepo.getDashboard()
            val earningsResult = earningsRepo.myEarnings()
            _state.update {
                it.copy(
                    isLoadingDashboard = false,
                    dashboard = (dashboardResult as? AppResult.Success)?.data ?: it.dashboard,
                    earnings = (earningsResult as? AppResult.Success)?.data ?: it.earnings,
                    error = (dashboardResult as? AppResult.Failure)?.error
                        ?: (earningsResult as? AppResult.Failure)?.error
                        ?: it.error,
                )
            }
        }
    }

    private suspend fun loadProducts(sellerId: String) {
        when (val result = sellerRepo.listMyProducts(sellerId)) {
            is AppResult.Success -> _state.update { it.copy(isLoading = false, products = result.data) }
            is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
        }
    }

    fun selectTab(tab: SalesTab) = _state.update { it.copy(selectedTab = tab) }

    private suspend fun loadOrders(sellerId: String) {
        _state.update { it.copy(isLoadingOrders = true) }
        when (val result = sellerRepo.listMyOrders(sellerId)) {
            is AppResult.Success -> _state.update { it.copy(isLoadingOrders = false, orders = result.data) }
            is AppResult.Failure -> _state.update { it.copy(isLoadingOrders = false, error = result.error) }
        }
    }

    // ── Seller application ──────────────────────────────────────────────────

    fun onBusinessNameChange(v: String) = updateApplicationForm { it.copy(businessName = v) }
    fun onSsmRegNoChange(v: String) = updateApplicationForm { it.copy(ssmRegNo = v) }

    fun onCommunityQueryChange(v: String) {
        updateApplicationForm { it.copy(communityQuery = v) }
        viewModelScope.launch {
            when (val result = addressRepo.searchCommunities(v)) {
                is AppResult.Success -> updateApplicationForm { it.copy(communityResults = result.data) }
                is AppResult.Failure -> Unit
            }
        }
    }

    fun onCommunitySelected(community: Community) = updateApplicationForm {
        it.copy(selectedCommunity = community, communityResults = emptyList(), communityQuery = community.name)
    }

    fun onCommunityCleared() = updateApplicationForm {
        it.copy(selectedCommunity = null, communityQuery = "", communityResults = emptyList())
    }

    fun submitApplication() {
        val form = _state.value.applicationForm
        val communityId = form.selectedCommunity?.id ?: return
        if (!form.canSubmit) return
        val draft = NewSeller(
            businessName = form.businessName.trim(),
            communityId = communityId,
            ssmRegNo = form.ssmRegNo.trim().takeIf { it.isNotEmpty() },
        )
        viewModelScope.launch {
            _state.update { it.copy(isSubmittingApplication = true, error = null) }
            when (val result = sellerRepo.applySeller(draft)) {
                is AppResult.Success -> _state.update {
                    it.copy(isSubmittingApplication = false, seller = result.data, isLoading = false)
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmittingApplication = false, error = result.error) }
            }
        }
    }

    private inline fun updateApplicationForm(transform: (SellerApplicationFormState) -> SellerApplicationFormState) =
        _state.update { it.copy(applicationForm = transform(it.applicationForm)) }

    // ── Product catalog ──────────────────────────────────────────────────────

    fun openNewProductForm() = _state.update { it.copy(productForm = ProductFormState()) }

    fun openEditProductForm(product: Product) = _state.update {
        it.copy(
            productForm = ProductFormState(
                editingId = product.id,
                title = product.title,
                description = product.description.orEmpty(),
                category = null, // see Product.kt: category is never known once read back
                priceRinggit = (product.priceSen.value / 100.0).let { v -> if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString() },
                unit = product.unit,
                weightGrams = product.weightGrams.toString(),
                minOrderQty = product.minOrderQty.toString(),
                handlingFlags = product.handlingFlags.toSet(),
            ),
        )
    }

    fun closeProductForm() = _state.update { it.copy(productForm = null) }

    fun onProductTitleChange(v: String) = updateProductForm { it.copy(title = v) }
    fun onProductDescriptionChange(v: String) = updateProductForm { it.copy(description = v) }
    fun onProductCategoryChange(v: KirimCategory) = updateProductForm { it.copy(category = v) }
    fun onProductPriceChange(v: String) = updateProductForm { it.copy(priceRinggit = v) }
    fun onProductUnitChange(v: String) = updateProductForm { it.copy(unit = v) }
    fun onProductWeightChange(v: String) = updateProductForm { it.copy(weightGrams = v.filter(Char::isDigit)) }
    fun onProductMinOrderQtyChange(v: String) = updateProductForm { it.copy(minOrderQty = v.filter(Char::isDigit)) }

    fun onProductHandlingFlagToggled(flag: HandlingFlag) = updateProductForm {
        it.copy(handlingFlags = if (flag in it.handlingFlags) it.handlingFlags - flag else it.handlingFlags + flag)
    }

    fun submitProduct() {
        val form = _state.value.productForm ?: return
        val draft = form.toDraftOrNull() ?: return
        val editingId = form.editingId
        viewModelScope.launch {
            _state.update { it.copy(isSubmittingProduct = true, error = null) }
            val result = if (editingId != null) sellerRepo.updateProduct(editingId, draft) else sellerRepo.createProduct(draft)
            when (result) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        isSubmittingProduct = false,
                        productForm = null,
                        products = if (editingId != null) {
                            it.products.map { p -> if (p.id == editingId) result.data.copy(images = p.images) else p }
                        } else {
                            listOf(result.data) + it.products
                        },
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(isSubmittingProduct = false, error = result.error) }
            }
        }
    }

    /** Direct status transitions the server already permits for a seller
     *  (submit for review, withdraw, pause, resume) -- see
     *  SellerRepository.setProductStatus's own doc comment on why this
     *  never surfaces an authorization error itself. */
    fun setProductStatus(productId: String, status: ProductStatus) {
        viewModelScope.launch {
            _state.update { it.copy(transitioningProductId = productId, error = null) }
            when (val result = sellerRepo.setProductStatus(productId, status)) {
                is AppResult.Success -> {
                    val seller = _state.value.seller
                    _state.update { it.copy(transitioningProductId = null) }
                    if (seller != null) loadProducts(seller.id)
                }
                is AppResult.Failure -> _state.update { it.copy(transitioningProductId = null, error = result.error) }
            }
        }
    }

    fun uploadProductImage(productId: String, photoBytes: ByteArray) {
        val nextSortOrder = _state.value.products.firstOrNull { it.id == productId }?.images?.size ?: 0
        viewModelScope.launch {
            _state.update { it.copy(uploadingImageForProductId = productId, error = null) }
            when (val result = sellerRepo.uploadProductImage(productId, nextSortOrder, photoBytes)) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        uploadingImageForProductId = null,
                        products = it.products.map { p ->
                            if (p.id == productId) p.copy(images = p.images + result.data) else p
                        },
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(uploadingImageForProductId = null, error = result.error) }
            }
        }
    }

    fun deleteProductImage(productId: String, imageId: String, storagePath: String) {
        viewModelScope.launch {
            when (val result = sellerRepo.deleteProductImage(imageId, storagePath)) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        products = it.products.map { p ->
                            if (p.id == productId) p.copy(images = p.images.filterNot { img -> img.id == imageId }) else p
                        },
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    private inline fun updateProductForm(transform: (ProductFormState) -> ProductFormState) =
        _state.update { s -> s.productForm?.let { s.copy(productForm = transform(it)) } ?: s }

    // ── Stock (0025) ──────────────────────────────────────────────────────
    // rpc_set_stock/rpc_adjust_stock are the only writers this client ever
    // calls -- on_hand/reserved/safety_stock/available all come back from
    // the server's own response, never computed here.

    fun openStockDialog(product: Product) {
        val inv = product.inventory
        _state.update {
            it.copy(
                stockDialog = StockDialogState(
                    productId = product.id,
                    current = inv,
                    onHandInput = (inv?.onHand ?: 0).toString(),
                    safetyStockInput = (inv?.safetyStock ?: 0).toString(),
                ),
            )
        }
        loadStockMovements(product.id)
    }

    fun closeStockDialog() = _state.update { it.copy(stockDialog = null) }

    fun onStockOnHandChange(v: String) = updateStockDialog { it.copy(onHandInput = v.filter(Char::isDigit)) }
    fun onStockSafetyChange(v: String) = updateStockDialog { it.copy(safetyStockInput = v.filter(Char::isDigit)) }
    fun onStockAdjustDeltaChange(v: String) =
        updateStockDialog { it.copy(adjustDeltaInput = v.filter { c -> c.isDigit() || c == '-' }) }

    private fun loadStockMovements(productId: String) {
        viewModelScope.launch {
            updateStockDialog { it.copy(isLoadingMovements = true) }
            when (val result = sellerRepo.listStockMovements(productId)) {
                is AppResult.Success -> updateStockDialog { it.copy(isLoadingMovements = false, movements = result.data) }
                is AppResult.Failure -> {
                    updateStockDialog { it.copy(isLoadingMovements = false) }
                    _state.update { it.copy(error = result.error) }
                }
            }
        }
    }

    /** Sets on_hand (and safety stock) to an absolute figure -- for "I
     *  counted the shelf and there are actually N units left", as opposed
     *  to applyStockAdjustment's relative delta. */
    fun saveStockAbsolute() {
        val dialog = _state.value.stockDialog ?: return
        val onHand = dialog.onHandOrNull ?: return
        val safety = dialog.safetyStockOrNull
        viewModelScope.launch {
            updateStockDialog { it.copy(isSaving = true) }
            _state.update { it.copy(error = null) }
            when (val result = sellerRepo.setStock(dialog.productId, onHand, safety)) {
                is AppResult.Success -> applyInventoryUpdate(dialog.productId, result.data)
                is AppResult.Failure -> {
                    updateStockDialog { it.copy(isSaving = false) }
                    _state.update { it.copy(error = result.error) }
                }
            }
        }
    }

    /** A relative movement (restock, spoilage, correction) -- rpc_adjust_stock
     *  records it as its own inventory_movements row under a fixed reason
     *  label, distinct from the absolute figure saveStockAbsolute writes. */
    fun applyStockAdjustment() {
        val dialog = _state.value.stockDialog ?: return
        val delta = dialog.adjustDeltaOrNull ?: return
        viewModelScope.launch {
            updateStockDialog { it.copy(isSaving = true) }
            _state.update { it.copy(error = null) }
            when (val result = sellerRepo.adjustStock(dialog.productId, delta)) {
                is AppResult.Success -> {
                    applyInventoryUpdate(dialog.productId, result.data)
                    updateStockDialog { it.copy(adjustDeltaInput = "") }
                    loadStockMovements(dialog.productId)
                }
                is AppResult.Failure -> {
                    updateStockDialog { it.copy(isSaving = false) }
                    _state.update { it.copy(error = result.error) }
                }
            }
        }
    }

    private fun applyInventoryUpdate(productId: String, inventory: Inventory) {
        _state.update { s ->
            s.copy(
                products = s.products.map { p -> if (p.id == productId) p.copy(inventory = inventory) else p },
                stockDialog = s.stockDialog?.copy(
                    isSaving = false,
                    current = inventory,
                    onHandInput = inventory.onHand.toString(),
                    safetyStockInput = inventory.safetyStock.toString(),
                ),
            )
        }
        loadDashboard()
    }

    private inline fun updateStockDialog(transform: (StockDialogState) -> StockDialogState) =
        _state.update { s -> s.stockDialog?.let { s.copy(stockDialog = transform(it)) } ?: s }

    // ── Archive ───────────────────────────────────────────────────────────

    fun openArchiveConfirm(productId: String) = _state.update { it.copy(archiveConfirmProductId = productId) }
    fun dismissArchiveConfirm() = _state.update { it.copy(archiveConfirmProductId = null) }

    fun confirmArchiveProduct() {
        val productId = _state.value.archiveConfirmProductId ?: return
        viewModelScope.launch {
            _state.update { it.copy(isArchivingProduct = true, error = null) }
            when (val result = sellerRepo.archiveProduct(productId)) {
                is AppResult.Success -> _state.update {
                    it.copy(
                        isArchivingProduct = false,
                        archiveConfirmProductId = null,
                        products = it.products.filterNot { p -> p.id == productId },
                    )
                }
                is AppResult.Failure -> _state.update { it.copy(isArchivingProduct = false, error = result.error) }
            }
        }
    }

    // ── Order detail + dispute (0035, 0030) ──────────────────────────────

    fun selectOrder(order: SellerOrder) {
        _state.update {
            it.copy(
                selectedOrder = order, selectedOrderStatus = null,
                showDisputeConfirm = false, disputeSubmitted = false,
            )
        }
        viewModelScope.launch {
            _state.update { it.copy(isLoadingOrderStatus = true) }
            when (val result = sellerRepo.getOrderStatus(order.id)) {
                is AppResult.Success -> _state.update { it.copy(isLoadingOrderStatus = false, selectedOrderStatus = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isLoadingOrderStatus = false, error = result.error) }
            }
        }
    }

    fun dismissOrderDetail() = _state.update { it.copy(selectedOrder = null, selectedOrderStatus = null) }

    fun openDisputeConfirm() = _state.update { it.copy(showDisputeConfirm = true) }
    fun dismissDisputeConfirm() = _state.update { it.copy(showDisputeConfirm = false) }

    /** rpc_delivery_transition(delivery, 'OPEN_DISPUTE') -- the same path
     *  0030 already authorizes a seller to take on their own order's
     *  delivery. Needs the delivery id from getOrderStatus's own read, since
     *  this client has no general SELECT on kirim_requests/deliveries to
     *  derive it another way. */
    fun confirmDispute() {
        val orderId = _state.value.selectedOrder?.id ?: return
        val deliveryId = _state.value.selectedOrderStatus?.deliveryId ?: return
        viewModelScope.launch {
            _state.update { it.copy(isFilingDispute = true, error = null) }
            when (val result = sellerRepo.openOrderDispute(deliveryId)) {
                is AppResult.Success -> {
                    _state.update { it.copy(isFilingDispute = false, showDisputeConfirm = false, disputeSubmitted = true) }
                    // Re-read directly, not via selectOrder(): that resets
                    // disputeSubmitted, which would erase the confirmation
                    // this same call just set.
                    when (val statusResult = sellerRepo.getOrderStatus(orderId)) {
                        is AppResult.Success -> _state.update { it.copy(selectedOrderStatus = statusResult.data) }
                        is AppResult.Failure -> Unit
                    }
                }
                is AppResult.Failure -> _state.update { it.copy(isFilingDispute = false, error = result.error) }
            }
        }
    }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val sellerRepo: SellerRepository,
        private val addressRepo: AddressRepository,
        private val earningsRepo: EarningsRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            SalesViewModel(sellerRepo, addressRepo, earningsRepo) as T
    }
}
