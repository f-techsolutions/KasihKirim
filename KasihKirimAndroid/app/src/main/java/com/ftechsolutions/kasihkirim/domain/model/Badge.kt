package com.ftechsolutions.kasihkirim.domain.model

/** public.user_badges joined (client-side -- ref schema isn't PostgREST-
 *  exposed, see 0021_badge_definitions_view.sql's own comment) to
 *  public.v_badge_definitions. icon is a plain emoji character from
 *  supabase/seed.sql's own catalog, rendered directly -- no icon-library
 *  mapping needed. */
data class Badge(
    val slug: String,
    val nameMs: String,
    val icon: String,
    val awardedAt: String,
)
