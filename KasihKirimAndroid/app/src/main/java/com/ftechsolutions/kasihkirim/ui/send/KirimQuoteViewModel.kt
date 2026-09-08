package com.ftechsolutions.kasihkirim.ui.send

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Community
import com.ftechsolutions.kasihkirim.domain.model.KirimCategory
import com.ftechsolutions.kasihkirim.domain.model.KirimDraft
import com.ftechsolutions.kasihkirim.domain.model.KirimQuote
import com.ftechsolutions.kasihkirim.domain.model.KirimType
import com.ftechsolutions.kasihkirim.domain.repository.AddressRepository
import com.ftechsolutions.kasihkirim.domain.repository.KirimRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.math.BigDecimal
import java.math.RoundingMode

/** Presentation-level bounds only, mirrored from the CHECK constraints in
 *  0001_schema.sql (VALIDATION_CONTRACT.md §4) -- not a business threshold
 *  like the budget ceiling, which stays server-side (BUDGET_CAP_EXCEEDED). */
private const val MIN_WEIGHT_GRAMS = 100
private const val MAX_WEIGHT_GRAMS = 500_000

data class KirimFormState(
    val kirimType: KirimType = KirimType.HANTAR,
    val category: KirimCategory? = null,
    val weightGrams: String = "",
    /** Ringgit, as typed -- converted to sen only at submit time. */
    val budgetRinggit: String = "",
    val originQuery: String = "",
    val originResults: List<Community> = emptyList(),
    val selectedOrigin: Community? = null,
    val destQuery: String = "",
    val destResults: List<Community> = emptyList(),
    val selectedDest: Community? = null,
) {
    private val weightValue: Int? get() = weightGrams.toIntOrNull()
    val weightValid: Boolean get() = weightValue?.let { it in MIN_WEIGHT_GRAMS..MAX_WEIGHT_GRAMS } == true

    private val budgetSenOrNull: Long?
        get() = budgetRinggit.toBigDecimalOrNull()
            ?.multiply(BigDecimal(100))
            ?.setScale(0, RoundingMode.HALF_UP)
            ?.toLong()

    /** BELI needs a positive budget (ck_beli_has_budget) -- format/presence
     *  only, matching VALIDATION_CONTRACT.md recommendation B. */
    val budgetValid: Boolean
        get() = kirimType != KirimType.BELI || (budgetSenOrNull?.let { it > 0 } == true)

    val canQuote: Boolean
        get() = category != null && weightValid && budgetValid &&
            selectedOrigin?.nodeId != null && selectedDest?.nodeId != null

    fun toDraftOrNull(): KirimDraft? {
        val category = category ?: return null
        val weight = weightValue ?: return null
        val originId = selectedOrigin?.nodeId ?: return null
        val destId = selectedDest?.nodeId ?: return null
        if (!weightValid || !budgetValid) return null
        return KirimDraft(
            kirimType = kirimType,
            category = category,
            estWeightGrams = weight,
            originNodeId = originId,
            destNodeId = destId,
            budgetSen = if (kirimType == KirimType.BELI) budgetSenOrNull ?: 0 else 0,
        )
    }
}

data class KirimUiState(
    val form: KirimFormState = KirimFormState(),
    val isQuoting: Boolean = false,
    val quote: KirimQuote? = null,
    val error: AppError? = null,
)

class KirimQuoteViewModel(
    private val kirimRepo: KirimRepository,
    private val addressRepo: AddressRepository,
) : ViewModel() {

    private val _state = MutableStateFlow(KirimUiState())
    val state: StateFlow<KirimUiState> = _state.asStateFlow()

    fun onKirimTypeChange(type: KirimType) = updateForm { it.copy(kirimType = type) }
    fun onCategorySelected(category: KirimCategory) = updateForm { it.copy(category = category) }
    fun onWeightChange(v: String) = updateForm { it.copy(weightGrams = v.filter(Char::isDigit)) }
    fun onBudgetChange(v: String) = updateForm { it.copy(budgetRinggit = v) }

    fun onOriginQueryChange(v: String) {
        updateForm { it.copy(originQuery = v) }
        searchCommunities(v) { results -> updateForm { it.copy(originResults = results) } }
    }

    fun onDestQueryChange(v: String) {
        updateForm { it.copy(destQuery = v) }
        searchCommunities(v) { results -> updateForm { it.copy(destResults = results) } }
    }

    fun onOriginSelected(community: Community) =
        updateForm { it.copy(selectedOrigin = community, originResults = emptyList(), originQuery = community.name) }

    fun onDestSelected(community: Community) =
        updateForm { it.copy(selectedDest = community, destResults = emptyList(), destQuery = community.name) }

    private fun searchCommunities(query: String, onResult: (List<Community>) -> Unit) {
        viewModelScope.launch {
            when (val result = addressRepo.searchCommunities(query)) {
                is AppResult.Success -> onResult(result.data)
                is AppResult.Failure -> _state.update { it.copy(error = result.error) }
            }
        }
    }

    fun quote() {
        val draft = _state.value.form.toDraftOrNull() ?: return
        viewModelScope.launch {
            _state.update { it.copy(isQuoting = true, error = null, quote = null) }
            when (val result = kirimRepo.quoteKirim(draft)) {
                is AppResult.Success -> _state.update { it.copy(isQuoting = false, quote = result.data) }
                is AppResult.Failure -> _state.update { it.copy(isQuoting = false, error = result.error) }
            }
        }
    }

    private inline fun updateForm(transform: (KirimFormState) -> KirimFormState) =
        _state.update { it.copy(form = transform(it.form)) }

    /** Manual DI, matching AuthViewModel.Factory (§9). */
    class Factory(
        private val kirimRepo: KirimRepository,
        private val addressRepo: AddressRepository,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T =
            KirimQuoteViewModel(kirimRepo, addressRepo) as T
    }
}
