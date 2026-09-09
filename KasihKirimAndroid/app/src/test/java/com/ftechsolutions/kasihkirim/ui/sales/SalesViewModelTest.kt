package com.ftechsolutions.kasihkirim.ui.sales

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.NewAddress
import com.ftechsolutions.kasihkirim.domain.model.NewProduct
import com.ftechsolutions.kasihkirim.domain.model.NewSeller
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductImage
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Sen
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.domain.model.Serviceability
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.SellerRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

private val KEPAYAN = Community(id = "c1", name = "Kg Kepayan Baru", type = "kampung", district = "Kota Kinabalu", state = "Sabah", nodeId = "n1")

private val APPROVED_SELLER = Seller(id = "s1", businessName = "Kedai Aisyah", status = SellerStatus.APPROVED, communityId = "c1", ssmRegNo = null)

private val DRAFT_PRODUCT = Product(
    id = "p1", title = "Ikan Bilis", description = null, status = ProductStatus.DRAFT,
    priceSen = Sen(1500), unit = "kg", weightGrams = 500, volumeCm3 = 8000,
    handlingFlags = emptyList(), minOrderQty = 1, rejectionReason = null, images = emptyList(),
)

private class FakeAddressRepository(var communities: List<Community> = listOf(KEPAYAN)) : AddressRepository {
    override suspend fun listAddresses() = throw NotImplementedError()
    override suspend fun createAddress(draft: NewAddress) = throw NotImplementedError()
    override suspend fun updateAddress(id: String, draft: NewAddress) = throw NotImplementedError()
    override suspend fun setDefaultAddress(id: String) = throw NotImplementedError()
    override suspend fun deleteAddress(id: String) = throw NotImplementedError()
    override suspend fun checkServiceability(originNodeId: String, destNodeId: String): AppResult<Serviceability> = throw NotImplementedError()
    override suspend fun searchCommunities(query: String): AppResult<List<Community>> = AppResult.Success(communities)
}

private class FakeSellerRepository(
    var seller: Seller? = null,
    var products: List<Product> = emptyList(),
    var applyResult: AppResult<Seller>? = null,
    var createProductResult: AppResult<Product>? = null,
) : SellerRepository {
    var setStatusCalls = 0
    var lastStatus: ProductStatus? = null

    override suspend fun getMySellerApplication(): AppResult<Seller?> = AppResult.Success(seller)

    override suspend fun applySeller(draft: NewSeller): AppResult<Seller> =
        applyResult ?: AppResult.Success(Seller(id = "s1", businessName = draft.businessName, status = SellerStatus.NOT_STARTED, communityId = draft.communityId, ssmRegNo = draft.ssmRegNo))

    override suspend fun listMyProducts(sellerId: String): AppResult<List<Product>> = AppResult.Success(products)

    override suspend fun createProduct(draft: NewProduct): AppResult<Product> =
        createProductResult ?: AppResult.Success(
            Product(
                id = "p1", title = draft.title, description = draft.description, status = ProductStatus.DRAFT,
                priceSen = Sen(draft.priceSen), unit = draft.unit, weightGrams = draft.weightGrams,
                volumeCm3 = draft.volumeCm3, handlingFlags = draft.handlingFlags, minOrderQty = draft.minOrderQty,
                rejectionReason = null, images = emptyList(),
            ),
        )

    override suspend fun updateProduct(id: String, draft: NewProduct): AppResult<Product> = throw NotImplementedError()

    override suspend fun setProductStatus(id: String, status: ProductStatus): AppResult<Unit> {
        setStatusCalls++
        lastStatus = status
        return AppResult.Success(Unit)
    }

    override suspend fun uploadProductImage(productId: String, sortOrder: Int, photoBytes: ByteArray): AppResult<ProductImage> =
        AppResult.Success(ProductImage(id = "img1", storagePath = "u/$productId/img1.jpg", sortOrder = sortOrder))

    override suspend fun deleteProductImage(imageId: String, storagePath: String): AppResult<Unit> = AppResult.Success(Unit)
}

@OptIn(ExperimentalCoroutinesApi::class)
class SalesViewModelTest {

    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)
    @After fun tearDown() = Dispatchers.resetMain()

    @Test fun `with no application, seller is null and no products are loaded`() = runTest(dispatcher) {
        val vm = SalesViewModel(FakeSellerRepository(seller = null), FakeAddressRepository())
        advanceUntilIdle()

        assertNull(vm.state.value.seller)
        assertTrue(vm.state.value.products.isEmpty())
        assertFalse(vm.state.value.isLoading)
    }

    @Test fun `an approved seller's products are loaded`() = runTest(dispatcher) {
        val vm = SalesViewModel(
            FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT)),
            FakeAddressRepository(),
        )
        advanceUntilIdle()

        assertEquals(APPROVED_SELLER, vm.state.value.seller)
        assertEquals(1, vm.state.value.products.size)
    }

    @Test fun `submitApplication sends the composed draft and stores the resulting seller`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = null)
        val vm = SalesViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onBusinessNameChange("Kedai Test")
        vm.onCommunitySelected(KEPAYAN)
        assertTrue(vm.state.value.applicationForm.canSubmit)

        vm.submitApplication(); advanceUntilIdle()

        assertNotNull(vm.state.value.seller)
        assertEquals("Kedai Test", vm.state.value.seller?.businessName)
        assertFalse(vm.state.value.isSubmittingApplication)
    }

    @Test fun `a failed application surfaces the error`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = null, applyResult = AppResult.Failure(AppError.Server("SELLER_APPLICATION_EXISTS")))
        val vm = SalesViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.onBusinessNameChange("Kedai Test")
        vm.onCommunitySelected(KEPAYAN)
        vm.submitApplication(); advanceUntilIdle()

        assertNull(vm.state.value.seller)
        assertEquals(AppError.Server("SELLER_APPLICATION_EXISTS"), vm.state.value.error)
    }

    @Test fun `submitProduct creates a new draft and prepends it to the catalog`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, products = emptyList())
        val vm = SalesViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.openNewProductForm()
        vm.onProductTitleChange("Ikan Bilis")
        vm.onProductCategoryChange(KirimCategory.HASIL_LAUT)
        vm.onProductPriceChange("15.00")
        vm.onProductWeightChange("500")
        assertTrue(vm.state.value.productForm!!.canSubmit)

        vm.submitProduct(); advanceUntilIdle()

        assertEquals(1, vm.state.value.products.size)
        assertEquals("Ikan Bilis", vm.state.value.products.first().title)
        assertNull(vm.state.value.productForm)
    }

    @Test fun `setProductStatus calls the repository and reloads the catalog`() = runTest(dispatcher) {
        val repo = FakeSellerRepository(seller = APPROVED_SELLER, products = listOf(DRAFT_PRODUCT))
        val vm = SalesViewModel(repo, FakeAddressRepository())
        advanceUntilIdle()

        vm.setProductStatus("p1", ProductStatus.PENDING_REVIEW); advanceUntilIdle()

        assertEquals(1, repo.setStatusCalls)
        assertEquals(ProductStatus.PENDING_REVIEW, repo.lastStatus)
        assertNull(vm.state.value.transitioningProductId)
    }
}
