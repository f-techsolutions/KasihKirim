package com.ftechsolutions.kasihkirim.domain.model

/** rpc_create_promotion / rpc_open_promotion's own p_subject_type
 *  (0045_kongsi_untung_promotions.sql). 'lot' exists in the underlying
 *  public.promotions CHECK (0006_carrier_commerce.sql) for a future Muatan
 *  Jual stock lot, but no RPC accepts it yet -- see that migration's own
 *  header comment -- so it is not modelled here. */
enum class PromotionSubjectType(val wire: String) {
    PRODUCT("product"),
    SELLER("seller"),
}

/** rpc_create_promotion's own result -- a freshly minted or re-fetched
 *  share code for one of the promoter's own subjects. */
data class CreatedPromotion(
    val id: String,
    val code: String,
    val subjectType: PromotionSubjectType,
    val subjectId: String,
    val shareLink: String,
)

/** rpc_open_promotion's own result. found=false covers both an unknown
 *  code and one whose subject no longer exists/is no longer live -- there
 *  is nothing further a client can do to distinguish those two cases, so
 *  neither is modelled separately. */
data class OpenedPromotion(
    val found: Boolean,
    val subjectType: PromotionSubjectType?,
    val subjectId: String?,
    val title: String?,
    val priceSen: Sen?,
    val sellerName: String?,
)

/** One row of rpc_my_promotions' own "promotions" array -- a promoter's
 *  own dashboard of every code they've made and where its earnings stand. */
data class MyPromotion(
    val id: String,
    val code: String,
    val subjectType: PromotionSubjectType,
    val subjectId: String,
    val subjectLabel: String?,
    val isActive: Boolean,
    val clickCount: Int,
    val pendingSen: Sen,
    val settledSen: Sen,
    val createdAt: String,
)

/** rpc_my_promotions' own top-level shape: the promoter's codes plus what's
 *  actually available to withdraw right now (PROMOTER_PAYABLE less anything
 *  already requested) -- the same figure rpc_request_withdrawal itself
 *  checks against. */
data class MyPromotions(
    val promotions: List<MyPromotion>,
    val availableSen: Sen,
)
