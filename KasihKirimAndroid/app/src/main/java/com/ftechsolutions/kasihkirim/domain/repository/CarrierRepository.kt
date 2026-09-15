package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.CarrierProfile
import com.ftechsolutions.kasihkirim.domain.model.NewCarrier

/**
 * Carrier onboarding (0040_carrier_onboarding_and_verification.sql) --
 * mirrors SellerRepository's own apply/read pair. Vehicle registration,
 * trips and deliveries are separate, pre-existing repositories
 * (VehicleRepository/TripRepository/DeliveryRepository); this is only the
 * carriers row itself, which none of those could reach before this existed
 * (no self-service way to create one at all).
 */
interface CarrierRepository {
    /** null means the caller has never applied. Reads the carriers table
     *  directly (own row, carriers_select's RLS), not the JWT's carrier_id
     *  claim -- that claim only exists once APPROVED (custom_access_token_
     *  hook), so it can't tell a NOT_STARTED applicant from a non-applicant. */
    suspend fun getMyCarrierApplication(): AppResult<CarrierProfile?>

    /** rpc_apply_carrier (0040). Fails if the caller already has a carriers
     *  row, at any status. */
    suspend fun applyCarrier(draft: NewCarrier): AppResult<CarrierProfile>
}
