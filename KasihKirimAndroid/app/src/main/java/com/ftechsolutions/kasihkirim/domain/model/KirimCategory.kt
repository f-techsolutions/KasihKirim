package com.ftechsolutions.kasihkirim.domain.model

/**
 * Mirrors ref.categories exactly as seeded (supabase/seed.sql) -- deck-
 * confirmed taxonomy (PRD.md §2.1/C-05), not fetched live: ref is not
 * PostgREST-exposed (supabase/config.toml), and this is a small, closed,
 * admin-seeded set, the same shape as UserRole.
 */
enum class KirimCategory(val slug: String, val nameMs: String) {
    SAYUR("sayur", "Sayur"),
    BUAH("buah", "Buah"),
    HASIL_LAUT("hasil-laut", "Hasil Laut"),
    KRAF("kraf", "Kraf"),
    LAIN_LAIN("lain-lain", "Lain-lain"),
}
