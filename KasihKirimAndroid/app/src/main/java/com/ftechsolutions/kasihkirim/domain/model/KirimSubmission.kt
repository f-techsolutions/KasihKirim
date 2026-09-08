package com.ftechsolutions.kasihkirim.domain.model

/** Input to rpc_create_kirim. Everything that affects price (type, category,
 *  weight, volume, corridor, handling, payment method) is read server-side
 *  from the quote itself -- see 0012_kirim_trip_creation.sql -- so it is
 *  deliberately absent here. */
data class KirimSubmission(
    val quoteId: String,
    val itemDescription: String,
    val destAddressId: String,
    /** Required when the quote's kirimType is HANTAR (ck_hantar_has_origin);
     *  ignored otherwise. */
    val originAddressId: String? = null,
    val declaredValueSen: Long? = null,
)

/** rpc_create_kirim's response shape (0012_kirim_trip_creation.sql). */
data class KirimCreated(
    val kirimId: String,
    val referenceCode: String,
    val expiresAt: String,
)
