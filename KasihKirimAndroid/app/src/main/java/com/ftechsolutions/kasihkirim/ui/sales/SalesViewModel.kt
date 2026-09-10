package com.ftechsolutions.kasihkirim.ui.sales

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerOrder
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
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

enum class SalesTab { PRODUCTS, ORDERS }

data class SalesUiState(
    val isLoading: Boolean = true,
    /** null once loaded means "never applied" -- see the empty-state screen. */
    val seller: Seller? = null,
    val products: List<Product> = emptyList(),
    val selectedTab: SalesTab = SalesTab.PRODUCTS,
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
)

class SalesViewModel(
    private val sellerRepo: SellerRepository,
    private val addressRepo: AddressRepository,
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
                    } else {
                        _state.update { it.copy(isLoading = false) }
                    }
                }
                is AppResult.Failure -> _state.update { it.copy(isLoading = false, error = result.error) }
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

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val sellerRepo: SellerRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = SalesViewModel(sellerRepo, addressRepo) as T
    }
}
