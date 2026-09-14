package com.ftechsolutions.kasihkirim.domain.model

/** public.carriers -- only the columns this client reads for the applicant's
 *  own view. Mirrors Seller.kt's own shape; status reuses [SellerStatus]
 *  since both map the same ref.verification_status enum (that type's own
 *  doc comment already calls out carriers as a second user of it). */
data class CarrierProfile(
    val id: String,
    val status: SellerStatus,
    val homeCommunityId: String?,
)

/** A carrier application the user is composing -- rpc_apply_carrier's params
 *  (0040_carrier_onboarding_and_verification.sql), 1:1. Deliberately just
 *  the community: tier/float_limit_sen/max_detour_km are admin-set risk
 *  parameters, not applicant input. */
data class NewCarrier(
    val homeCommunityId: String,
)
