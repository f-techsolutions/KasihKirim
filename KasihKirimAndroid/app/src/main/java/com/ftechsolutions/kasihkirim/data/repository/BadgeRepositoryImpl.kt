package com.ftechsolutions.kasihkirim.data.repository

import com.ftechsolutions.kasihkirim.core.result.AppError
import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.core.security.SafeLog
import com.ftechsolutions.kasihkirim.data.remote.SupabaseClientProvider
import com.ftechsolutions.kasihkirim.data.remote.dto.BadgeDefinitionDto
import com.ftechsolutions.kasihkirim.data.remote.dto.UserBadgeDto
import com.ftechsolutions.kasihkirim.domain.model.Badge
import com.ftechsolutions.kasihkirim.domain.repository.BadgeRepository
import io.github.jan.supabase.auth.auth
import io.github.jan.supabase.postgrest.postgrest
import java.io.IOException

class BadgeRepositoryImpl : BadgeRepository {

    private val tag = "BadgeRepository"

    override suspend fun listMyBadges(): AppResult<List<Badge>> =
        try {
            val userId = SupabaseClientProvider.client.auth.currentUserOrNull()?.id
                ?: throw IllegalStateException("SESSION_EXPIRED")
            val earned = SupabaseClientProvider.client.postgrest.from("user_badges")
                .select { filter { eq("user_id", userId) } }
                .decodeList<UserBadgeDto>()
            if (earned.isEmpty()) {
                AppResult.Success(emptyList())
            } else {
                // v_badge_definitions is a small, whole-catalog view (0021)
                // -- no embed assumed across it (views do not reliably carry
                // FK metadata for Postgrest's embed inference), so the two
                // are joined here instead.
                val definitions = SupabaseClientProvider.client.postgrest.from("v_badge_definitions")
                    .select()
                    .decodeList<BadgeDefinitionDto>()
                    .associateBy { it.id }
                AppResult.Success(
                    earned.mapNotNull { ub ->
                        definitions[ub.badgeId]?.let { def ->
                            Badge(slug = def.slug, nameMs = def.nameMs, icon = def.icon, awardedAt = ub.awardedAt)
                        }
                    }.sortedBy { it.awardedAt },
                )
            }
        } catch (t: Throwable) {
            SafeLog.e(tag, "badge call failed: ${t::class.simpleName}", t)
            AppResult.Failure(t.toBadgeAppError())
        }
}

private fun Throwable.toBadgeAppError(): AppError = when {
    message?.contains("SESSION_EXPIRED", true) == true -> AppError.SessionExpired
    this is IOException -> AppError.Network
    message?.contains("timeout", true) == true -> AppError.Timeout
    message?.contains("JWT", true) == true -> AppError.SessionExpired
    message?.contains("row-level security", true) == true -> AppError.NotAuthorized
    message?.contains("permission denied", true) == true -> AppError.NotAuthorized
    else -> AppError.Unexpected
}
