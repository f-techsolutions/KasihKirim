package com.ftechsolutions.kasihkirim.domain.model

/**
 * The non-proof subset of ref.delivery_transition_rules (seed.sql) offered
 * as UI affordances in this client.
 *
 * Deliberately absent:
 *   - CONFIRM_PICKUP, CONFIRM_DELIVERY, CONFIRM_RETURN (requires_proof=true).
 *     See [PROOF_DELIVERY_TRANSITIONS] below -- these go through a photo
 *     capture + rpc_submit_proof step first. (Correction: an earlier version
 *     of this comment claimed internal.fn_delivery_transition never enforces
 *     requires_proof; reading its live definition shows it does -- a
 *     transition whose rule has requires_proof=true raises PROOF_REQUIRED if
 *     no matching public.proofs row exists yet. The UI gap this comment
 *     describes was real regardless: no button meant no way to create that
 *     proofs row from the app at all.)
 *   - RECORD_PURCHASE. fn_delivery_transition never applies p_meta to
 *     kirim_requests.actual_goods_sen, so a form field for the actual
 *     purchase price would silently discard whatever the carrier typed.
 *   - RAISE_VARIANCE. Not proof-gated by this table, but
 *     public.price_variances.evidence_photo_path is NOT NULL -- it needs a
 *     photo through a different mechanism, same storage blocker.
 *
 * Android never DECIDES a transition -- the server re-validates every one
 * of these against ref.delivery_transition_rules itself (Android is not
 * PostgREST-exposed to that table, ref isn't in config.toml's schema
 * list). This list only decides which buttons to SHOW; a stale entry here
 * fails safely as a rejected RPC call, never a silently wrong status.
 */
data class DeliveryTransitionRule(
    val fromStatus: KirimStatus,
    val event: String,
    val toStatus: KirimStatus,
    val allowedRoles: Set<UserRole>,
    val applicableTypes: Set<KirimType>,
)

private val ALL_TYPES = setOf(KirimType.BELI, KirimType.HANTAR, KirimType.PASARAN)

val NON_PROOF_DELIVERY_TRANSITIONS = listOf(
    DeliveryTransitionRule(KirimStatus.MATCHED, "START_PROCUREMENT", KirimStatus.PROCURING,
        setOf(UserRole.CARRIER), setOf(KirimType.BELI)),
    DeliveryTransitionRule(KirimStatus.MATCHED, "GO_TO_PICKUP", KirimStatus.AWAITING_PICKUP,
        setOf(UserRole.CARRIER), setOf(KirimType.HANTAR, KirimType.PASARAN)),
    DeliveryTransitionRule(KirimStatus.MATCHED, "CANCEL", KirimStatus.CANCELLED,
        setOf(UserRole.CUSTOMER, UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.PROCURING, "PROCUREMENT_FAILED", KirimStatus.PROCUREMENT_FAILED,
        setOf(UserRole.CARRIER), setOf(KirimType.BELI)),
    DeliveryTransitionRule(KirimStatus.AWAITING_PICKUP, "REPORT_FAILURE", KirimStatus.FAILED_PICKUP,
        setOf(UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.AWAITING_PICKUP, "CANCEL", KirimStatus.CANCELLED,
        setOf(UserRole.CUSTOMER, UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.PICKED_UP, "DEPART", KirimStatus.IN_TRANSIT,
        setOf(UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.IN_TRANSIT, "ARRIVE_HUB", KirimStatus.AT_HUB,
        setOf(UserRole.CARRIER, UserRole.AGENT), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.AT_HUB, "LEAVE_HUB", KirimStatus.IN_TRANSIT,
        setOf(UserRole.CARRIER, UserRole.AGENT), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.IN_TRANSIT, "START_DELIVERY", KirimStatus.OUT_FOR_DELIVERY,
        setOf(UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.OUT_FOR_DELIVERY, "REPORT_FAILURE", KirimStatus.FAILED_DELIVERY,
        setOf(UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.FAILED_PICKUP, "RETRY", KirimStatus.AWAITING_PICKUP,
        setOf(UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.FAILED_PICKUP, "CANCEL", KirimStatus.CANCELLED,
        setOf(UserRole.CUSTOMER, UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.FAILED_DELIVERY, "RETRY", KirimStatus.OUT_FOR_DELIVERY,
        setOf(UserRole.CARRIER), ALL_TYPES),
    // Found in review: seed.sql grants this (FAILED_DELIVERY -> RETURNING),
    // but no button ever offered it, leaving the already-defined
    // CONFIRM_RETURN proof step below permanently unreachable -- a carrier
    // who genuinely cannot redeliver had no in-app way out of FAILED_DELIVERY
    // beyond RETRY.
    DeliveryTransitionRule(KirimStatus.FAILED_DELIVERY, "RETURN", KirimStatus.RETURNING,
        setOf(UserRole.CARRIER), ALL_TYPES),
    DeliveryTransitionRule(KirimStatus.DELIVERED, "CONFIRM_RECEIPT", KirimStatus.COMPLETED,
        setOf(UserRole.CUSTOMER, UserRole.AGENT), ALL_TYPES),
)

/**
 * The three requires_proof=true rows of ref.delivery_transition_rules,
 * exactly as read from the live schema (proof_leg/allowed_roles included).
 * [leg] mirrors ref.handover_leg's wire values ("pickup"/"dropoff") and is
 * exactly what rpc_submit_proof's p_leg expects -- the app must call
 * rpc_submit_proof for this leg before rpc_delivery_transition's own event,
 * or the server rejects the transition with PROOF_REQUIRED.
 */
data class ProofDeliveryTransitionRule(
    val fromStatus: KirimStatus,
    val event: String,
    val toStatus: KirimStatus,
    val leg: String,
    val allowedRoles: Set<UserRole>,
)

val PROOF_DELIVERY_TRANSITIONS = listOf(
    ProofDeliveryTransitionRule(KirimStatus.AWAITING_PICKUP, "CONFIRM_PICKUP", KirimStatus.PICKED_UP,
        "pickup", setOf(UserRole.CARRIER, UserRole.AGENT)),
    ProofDeliveryTransitionRule(KirimStatus.OUT_FOR_DELIVERY, "CONFIRM_DELIVERY", KirimStatus.DELIVERED,
        "dropoff", setOf(UserRole.CARRIER, UserRole.AGENT)),
    ProofDeliveryTransitionRule(KirimStatus.RETURNING, "CONFIRM_RETURN", KirimStatus.RETURNED,
        "dropoff", setOf(UserRole.CARRIER, UserRole.AGENT)),
)
