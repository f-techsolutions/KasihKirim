@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.ftechsolutions.kasihkirim.ui.sales

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddAPhoto
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.ftechsolutions.kasihkirim.R
import com.ftechsolutions.kasihkirim.domain.model.HandlingFlag
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.Product
import com.ftechsolutions.kasihkirim.domain.model.ProductStatus
import com.ftechsolutions.kasihkirim.domain.model.Seller
import com.ftechsolutions.kasihkirim.domain.model.SellerStatus
import com.ftechsolutions.kasihkirim.ui.auth.messageRes
import com.ftechsolutions.kasihkirim.ui.common.AppCard
import com.ftechsolutions.kasihkirim.ui.common.BadgeTone
import com.ftechsolutions.kasihkirim.ui.common.CommunityPicker
import com.ftechsolutions.kasihkirim.ui.common.ScreenHeader
import com.ftechsolutions.kasihkirim.ui.common.StatusBadge
import java.io.ByteArrayOutputStream

@Composable
fun SalesScreen(vm: SalesViewModel, onBack: () -> Unit) {
    val state by vm.state.collectAsState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.sales_title)) },
                navigationIcon = {
                    TextButton(onClick = onBack) { Text(stringResource(R.string.back)) }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding)) {
            when {
                state.isLoading && state.seller == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
                state.seller == null -> SellerApplicationScreen(vm)
                !state.seller!!.status.isUsable -> SellerStatusScreen(state.seller!!)
                else -> ProductCatalogScreen(vm)
            }
        }
    }
}

@Composable
private fun SellerApplicationScreen(vm: SalesViewModel) {
    val state by vm.state.collectAsState()
    val form = state.applicationForm

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { Spacer(Modifier.height(4.dp)) }
        item {
            Text(
                stringResource(R.string.sales_apply_intro),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        item {
            AppCard {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    OutlinedTextField(
                        value = form.businessName,
                        onValueChange = vm::onBusinessNameChange,
                        label = { Text(stringResource(R.string.sales_business_name)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = form.ssmRegNo,
                        onValueChange = vm::onSsmRegNoChange,
                        label = { Text(stringResource(R.string.sales_ssm_reg_no)) },
                        singleLine = true,
                        shape = MaterialTheme.shapes.small,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    CommunityPicker(
                        label = stringResource(R.string.sales_community),
                        hint = stringResource(R.string.picker_search_hint),
                        changeLabel = stringResource(R.string.picker_change),
                        notSelectedHint = stringResource(R.string.picker_not_selected),
                        query = form.communityQuery,
                        selected = form.selectedCommunity,
                        results = form.communityResults,
                        onQueryChange = vm::onCommunityQueryChange,
                        onSelect = vm::onCommunitySelected,
                        onClear = vm::onCommunityCleared,
                    )
                    Button(
                        onClick = vm::submitApplication,
                        enabled = form.canSubmit && !state.isSubmittingApplication,
                        shape = MaterialTheme.shapes.medium,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
                    ) {
                        if (state.isSubmittingApplication) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        } else {
                            Text(stringResource(R.string.sales_apply_submit))
                        }
                    }
                }
            }
        }
        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun SellerStatusScreen(seller: Seller) {
    Column(
        Modifier.fillMaxSize().padding(20.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        AppCard {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                Text(seller.businessName, style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.height(8.dp))
                StatusBadge(
                    seller.status.labelMs,
                    tone = if (seller.status == SellerStatus.REJECTED || seller.status == SellerStatus.SUSPENDED ||
                        seller.status == SellerStatus.REVOKED
                    ) {
                        BadgeTone.ERROR
                    } else {
                        BadgeTone.WARNING
                    },
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    stringResource(R.string.sales_status_pending_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ProductCatalogScreen(vm: SalesViewModel) {
    val state by vm.state.collectAsState()

    LazyColumn(
        modifier = Modifier.fillMaxSize().padding(horizontal = 20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { Spacer(Modifier.height(4.dp)) }

        if (state.products.isEmpty() && state.productForm == null) {
            item {
                AppCard {
                    Text(stringResource(R.string.sales_no_products), style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        items(state.products, key = { it.id }) { product ->
            ProductCard(
                product = product,
                isTransitioning = state.transitioningProductId == product.id,
                isUploadingImage = state.uploadingImageForProductId == product.id,
                onEdit = { vm.openEditProductForm(product) },
                onSubmitForReview = { vm.setProductStatus(product.id, ProductStatus.PENDING_REVIEW) },
                onWithdraw = { vm.setProductStatus(product.id, ProductStatus.DRAFT) },
                onPause = { vm.setProductStatus(product.id, ProductStatus.PAUSED) },
                onResume = { vm.setProductStatus(product.id, ProductStatus.ACTIVE) },
                onPhotoTaken = { bytes -> vm.uploadProductImage(product.id, bytes) },
                onDeleteImage = { imageId, path -> vm.deleteProductImage(product.id, imageId, path) },
            )
        }

        if (state.productForm != null) {
            item {
                Spacer(Modifier.height(4.dp))
                ScreenHeader(
                    stringResource(if (state.productForm!!.isEditing) R.string.sales_edit_product else R.string.sales_add_product),
                )
            }
            item { AppCard { ProductForm(vm) } }
        } else {
            item {
                OutlinedButton(onClick = vm::openNewProductForm, modifier = Modifier.fillMaxWidth()) {
                    Text(stringResource(R.string.sales_add_product))
                }
            }
        }

        state.error?.let { item { Text(stringResource(it.messageRes()), color = MaterialTheme.colorScheme.error) } }
        item { Spacer(Modifier.height(24.dp)) }
    }
}

@Composable
private fun ProductCard(
    product: Product,
    isTransitioning: Boolean,
    isUploadingImage: Boolean,
    onEdit: () -> Unit,
    onSubmitForReview: () -> Unit,
    onWithdraw: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onPhotoTaken: (ByteArray) -> Unit,
    onDeleteImage: (imageId: String, storagePath: String) -> Unit,
) {
    val cameraLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.TakePicturePreview(),
    ) { bitmap: Bitmap? ->
        if (bitmap != null) {
            val bytes = ByteArrayOutputStream()
                .apply { bitmap.compress(Bitmap.CompressFormat.JPEG, 80, this) }
                .toByteArray()
            onPhotoTaken(bytes)
        }
    }

    AppCard {
        Row(verticalAlignment = Alignment.Top) {
            Text(product.title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
            StatusBadge(product.status.labelMs, tone = product.status.tone())
        }
        Spacer(Modifier.height(4.dp))
        Text(
            "${product.priceSen.format()} / ${product.unit}",
            style = MaterialTheme.typography.bodyMedium,
        )
        product.rejectionReason?.let {
            Spacer(Modifier.height(2.dp))
            Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        }

        Spacer(Modifier.height(10.dp))
        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(product.images, key = { it.id }) { image ->
                // No image-loading library in this module yet -- a numbered
                // placeholder confirms the upload/delete round trip without
                // pulling in a new dependency for a Phase A thumbnail. The
                // photo itself is already the one the buyer will see
                // (product-images is a public bucket) once a marketplace
                // browse screen exists to render it.
                Box(contentAlignment = Alignment.TopEnd) {
                    Surface(
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.size(64.dp),
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.Photo, contentDescription = null)
                        }
                    }
                    Surface(
                        shape = CircleShape,
                        color = MaterialTheme.colorScheme.surface,
                        modifier = Modifier
                            .size(18.dp)
                            .clickable { onDeleteImage(image.id, image.storagePath) },
                    ) {
                        Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.sales_remove_photo), modifier = Modifier.padding(2.dp))
                    }
                }
            }
            if (product.images.size < 6) {
                item {
                    Surface(
                        shape = MaterialTheme.shapes.small,
                        color = MaterialTheme.colorScheme.surfaceVariant,
                        modifier = Modifier.size(64.dp).clickable(enabled = !isUploadingImage) { cameraLauncher.launch(null) },
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            if (isUploadingImage) {
                                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                            } else {
                                Icon(Icons.Filled.AddAPhoto, contentDescription = stringResource(R.string.sales_add_photo))
                            }
                        }
                    }
                }
            }
        }

        HorizontalDivider(Modifier.padding(top = 12.dp, bottom = 8.dp), color = MaterialTheme.colorScheme.outlineVariant)
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            TextButton(onClick = onEdit, enabled = !isTransitioning) { Text(stringResource(R.string.sales_edit)) }
            when (product.status) {
                ProductStatus.DRAFT -> TextButton(onClick = onSubmitForReview, enabled = !isTransitioning) {
                    Text(stringResource(R.string.sales_submit_for_review))
                }
                ProductStatus.PENDING_REVIEW -> TextButton(onClick = onWithdraw, enabled = !isTransitioning) {
                    Text(stringResource(R.string.sales_withdraw))
                }
                ProductStatus.ACTIVE -> TextButton(onClick = onPause, enabled = !isTransitioning) {
                    Text(stringResource(R.string.sales_pause))
                }
                ProductStatus.PAUSED -> TextButton(onClick = onResume, enabled = !isTransitioning) {
                    Text(stringResource(R.string.sales_resume))
                }
                ProductStatus.REJECTED -> TextButton(onClick = onWithdraw, enabled = !isTransitioning) {
                    Text(stringResource(R.string.sales_revise))
                }
                ProductStatus.DELISTED -> Unit
            }
        }
    }
}

@Composable
private fun ProductForm(vm: SalesViewModel) {
    val state by vm.state.collectAsState()
    val form = state.productForm ?: return

    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedTextField(
            value = form.title,
            onValueChange = vm::onProductTitleChange,
            label = { Text(stringResource(R.string.sales_product_title)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.description,
            onValueChange = vm::onProductDescriptionChange,
            label = { Text(stringResource(R.string.sales_product_description)) },
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
            minLines = 2,
        )

        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            KirimCategory.entries.forEach { category ->
                FilterChip(
                    selected = form.category == category,
                    onClick = { vm.onProductCategoryChange(category) },
                    label = { Text(category.nameMs) },
                )
            }
        }
        if (form.isEditing && form.category == null) {
            Text(
                stringResource(R.string.sales_category_reselect_hint),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        OutlinedTextField(
            value = form.priceRinggit,
            onValueChange = vm::onProductPriceChange,
            label = { Text(stringResource(R.string.sales_product_price)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.unit,
            onValueChange = vm::onProductUnitChange,
            label = { Text(stringResource(R.string.sales_product_unit)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.weightGrams,
            onValueChange = vm::onProductWeightChange,
            label = { Text(stringResource(R.string.sales_product_weight)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = form.minOrderQty,
            onValueChange = vm::onProductMinOrderQtyChange,
            label = { Text(stringResource(R.string.sales_product_min_order_qty)) },
            singleLine = true,
            shape = MaterialTheme.shapes.small,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            modifier = Modifier.fillMaxWidth(),
        )

        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            HandlingFlag.entries.forEach { flag ->
                FilterChip(
                    selected = flag in form.handlingFlags,
                    onClick = { vm.onProductHandlingFlagToggled(flag) },
                    label = { Text(flag.labelMs) },
                )
            }
        }

        Button(
            onClick = vm::submitProduct,
            enabled = form.canSubmit && !state.isSubmittingProduct,
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) {
            if (state.isSubmittingProduct) {
                CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
            } else {
                Text(stringResource(if (form.isEditing) R.string.sales_update_product else R.string.sales_save_product))
            }
        }
        TextButton(onClick = vm::closeProductForm, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.sales_cancel))
        }
    }
}

private fun ProductStatus.tone(): BadgeTone = when (this) {
    ProductStatus.ACTIVE -> BadgeTone.POSITIVE
    ProductStatus.REJECTED, ProductStatus.DELISTED -> BadgeTone.ERROR
    ProductStatus.DRAFT -> BadgeTone.NEUTRAL
    ProductStatus.PENDING_REVIEW, ProductStatus.PAUSED -> BadgeTone.WARNING
}
