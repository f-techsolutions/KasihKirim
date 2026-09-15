package com.ftechsolutions.kasihkirim.domain.model

/** The signed-in user, as far as the client is allowed to know. */
data class AuthUser(
    val id: String,
    val email: String?,
    val roles: Set<UserRole>,
    val carrierId: String?,
    val sellerId: String?,
    val accountStatus: String?,
) {
    /** Navigation only. RLS decides what is actually readable.
     *
     *  Admin wins over carrier/seller: someone holding both is here to review
     *  the queues, and every admin_* role resolves to the same tab set. */
    val primaryRole: UserRole
        get() = roles.filter { it.isAdmin }.maxByOrNull { it.ordinal }
            ?: when {
                UserRole.CARRIER in roles -> UserRole.CARRIER
                UserRole.SELLER in roles -> UserRole.SELLER
                else -> UserRole.CUSTOMER
            }
}

/** §14 requires an explicit four-state model. Initializing is distinct from
 *  Unauthenticated so the UI never flashes a sign-in screen during restore. */
sealed interface AuthState {
    data object Initializing : AuthState
    data class Authenticated(val user: AuthUser) : AuthState
    data object Unauthenticated : AuthState
    data class Error(val error: com.ftechsolutions.kasihkirim.core.result.AppError) : AuthState
}
