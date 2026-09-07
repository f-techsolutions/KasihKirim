package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors ref.user_role exactly (0000_prelude.sql).
 *
 * Values arrive in the JWT app_metadata.roles claim, set by
 * public.custom_access_token_hook. They drive NAVIGATION ONLY -- authorization
 * is RLS. A tampered client can reach a screen but cannot read a row.
 */
enum class UserRole(val wire: String) {
    CUSTOMER("customer"),
    SELLER("seller"),
    CARRIER("carrier"),
    AGENT("agent"),
    ADMIN_SUPPORT("admin_support"),
    ADMIN_OPS("admin_ops"),
    ADMIN_FINANCE("admin_finance"),
    ADMIN_COMPLIANCE("admin_compliance"),
    ADMIN_SUPER("admin_super");

    val isAdmin: Boolean get() = wire.startsWith("admin_")

    companion object {
        /** Unknown values are dropped, never guessed: the backend may add a
         *  role before this build knows about it. */
        fun fromWire(value: String): UserRole? = entries.firstOrNull { it.wire == value }
        fun parseAll(values: List<String>): Set<UserRole> = values.mapNotNull(::fromWire).toSet()
    }
}
