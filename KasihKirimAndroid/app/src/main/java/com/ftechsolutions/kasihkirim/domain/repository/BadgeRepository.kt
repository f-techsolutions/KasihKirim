package com.ftechsolutions.kasihkirim.domain.repository

import com.ftechsolutions.kasihkirim.core.result.AppResult
import com.ftechsolutions.kasihkirim.domain.model.Badge

/** public.user_badges (own rows, no RLS restriction beyond that -- see
 *  0001_schema.sql) joined client-side to public.v_badge_definitions
 *  (0021_badge_definitions_view.sql). */
interface BadgeRepository {
    suspend fun listMyBadges(): AppResult<List<Badge>>
}
