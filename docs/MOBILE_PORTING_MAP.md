# Mobile Porting Map — Expo → Native Kotlin

`apps/mobile/` stays in the repository as the **reference implementation**. It is
not deleted and not maintained in parallel. This table records what carries
over, what gets rebuilt, and what was never client concern.

Source read: 20 files under `apps/mobile/`, commit `a9eacbc`.

| Expo component | Existing purpose | Kotlin equivalent | Backend contract | Status | Notes |
|---|---|---|---|---|---|
| `src/core/api/supabase.ts` | Single client, PKCE-adjacent, Keystore token storage via `expo-secure-store` | `data/remote/SupabaseClientProvider.kt` | Supabase Auth + PostgREST | **PORT — done** | Kotlin SDK stores tokens in `EncryptedSharedPreferences`; `FlowType.PKCE` explicit |
| `currentRoles()` reading JWT claim | Roles from `app_metadata`, never a table join | `AuthRepositoryImpl.toAuthUser()` | `public.custom_access_token_hook` | **PORT — done** | Unknown roles dropped, not guessed |
| `src/ui/tokens.ts` | Brand palette from the deck | `ui/theme/Theme.kt` | — | **PORT — done** | Same greens/gold/cream |
| `src/core/i18n/index.ts` | ms-MY default, en fallback | `res/values/strings.xml` (+ future `values-en/`) | — | **REIMPLEMENT — partial** | Android resources are the right mechanism; ms-MY is the default locale |
| `src/features/kirim/schema.ts` (Zod) | Client-side draft validation, shared with Edge Function | `domain/model/` + a Phase 3 `KirimDraft` validator | `rpc_quote_kirim` | **REIMPLEMENT — Phase 3** | The shared-definition property is **lost** in a native move. See Risk below. |
| `src/core/db/schema.ts` (SQLite) | `outbox`, `media_queue`, `cache_entities`, `sync_cursors` | Room, Phase 6 | — | **PORT — Phase 6** | Schema documented in `OFFLINE_ARCHITECTURE.md` |
| `src/core/sync/outbox.ts` | Enqueue, exponential backoff + jitter, `depends_on` ordering, 10-attempt give-up | `data/local/OutboxDao` + `WorkManager`, Phase 6 | `p_idempotency_key` on RPCs | **PORT — Phase 6** | Retry curve preserved exactly |
| `src/core/net/status.ts` | Connectivity detection, flush trigger | `ConnectivityManager` callback, Phase 6 | — | **REIMPLEMENT — Phase 6** | |
| `app/(auth)/phone.tsx`, `otp.tsx` | Phone + OTP screens | **none** | — | **NOT REQUIRED (yet)** | `supabase/config.toml` has an `[auth.sms]` template but **no provider block**. Building the UI would promise what the backend cannot do. |
| `app/(customer)/kirim-baru.tsx` | Kirim wizard step 1 | Phase 3 | `rpc_quote_kirim` | **REIMPLEMENT — Phase 3** | |
| `app/(customer)/index.tsx` | Customer home | `ui/home/HomeScreen.kt` | — | **REIMPLEMENT — placeholder now** | |
| `eas.json` | EAS build profiles | `.github/workflows/android-cloud-build.yml` | — | **DEPRECATED** | Cloud build is GitHub Actions |
| `supabase/functions/_shared/idempotency.ts` | Idempotency storage | — | `rpc_idem_*` | **BACKEND-ONLY** | `service_role`; Android must never call it |
| Payment webhook handling | — | — | `rpc_apply_payment_event` | **BACKEND-ONLY** | |

## Risk recorded, not solved

The Zod schema in `apps/mobile/src/features/kirim/schema.ts` is **one definition
validated on both the client and the Edge Function**. A Kotlin client cannot
share it. The two validators will drift unless something keeps them honest.

Options for Phase 3, none chosen yet: generate Kotlin from the Zod schema; move
validation entirely server-side and let the client submit and render errors; or
accept drift and cover it with contract tests. **This needs a decision before
Kirim submission is built.**
