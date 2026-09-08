package com.ftechsolutions.kasihkirim.domain.model

/**
 * The non-proof subset of ref.delivery_transition_rules (seed.sql) offered
 * as UI affordances in this client.
 *
 * Deliberately absent:
 *   - CONFIRM_PICKUP, CONFIRM_DELIVERY, CONFIRM_RETURN (requires_proof=true).
 *     internal.fn_delivery_transition reads that flag but never enforces
 *     it -- offering these buttons today would let a client fake a
 *     handover with zero photo evidence. Deferred until proof capture and
 *     a storage bucket exist.
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
    DeliveryTransitionRule(KirimStatus.DELIVERED, "CONFIRM_RECEIPT", KirimStatus.COMPLETED,
        setOf(UserRole.CUSTOMER, UserRole.AGENT), ALL_TYPES),
)
