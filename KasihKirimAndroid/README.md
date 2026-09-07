# KasihKirim Native Android — Phase 1

This is the native Kotlin/Jetpack Compose Phase 1 implementation package generated from the supplied KasihKirim repository.

It provides:
- Kotlin + Compose foundation
- Supabase Kotlin client
- PKCE
- email/password authentication
- session restoration
- logout
- bottom navigation shell
- documentation of verified backend RPCs
- Expo-to-Kotlin porting map
- offline architecture notes

It deliberately does not fake production Kirim/business functionality.

Next work:
1. verify build on Android machine/CI
2. port profile/roles
3. port real Kirim quote flow
4. port serviceability
5. port carrier/matching/delivery workflows
6. port offline outbox
7. implement compliance-gated Muatan Jual
8. production hardening
