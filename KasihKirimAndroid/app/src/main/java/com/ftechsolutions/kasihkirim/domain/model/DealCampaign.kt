package com.ftechsolutions.kasihkirim.domain.model

/** public.v_deal_campaigns (0048) -- an admin-curated deal shown to every
 *  buyer, distinct from Promotion.kt's own referral codes (Kongsi &
 *  Untung): that is a buyer/promoter's own shareable link, this is a small,
 *  admin-picked set of featured listings, the same way a marketplace app's
 *  home page highlights a handful of deals. The view already applies the
 *  active-window-and-live-product predicate server-side (v_deal_campaigns'
 *  own WHERE clause), so every row this client sees is meant to be shown --
 *  no client-side filtering of its own. */
data class DealCampaign(
    val id: String,
    val title: String,
    val subtitle: String?,
    val imagePath: String,
    val productId: String,
    val productTitle: String,
    val priceSen: Sen,
    val unit: String,
)
