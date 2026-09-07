# KasihKirim — Implementation Plan

**F-Tech Solutions** · Android (Kotlin/Compose) on an existing Supabase backend
**Scope: ALL SABAH.** Beluran / Paitan / Kota Kinabalu are the initial pilot corridor, not the boundary.

Audit date: 2026-09-05. Everything below was read from the repository. Nothing is assumed.

---

## 0. Two things to settle before any Kotlin is written

### 0.1 ⚠ Stack conflict — the repository already has a mobile app

| | |
|---|---|
| **In the repo** | `apps/mobile/` — **Expo SDK 52 / React Native 0.76.5 / TypeScript**, 20 files, `@supabase/supabase-js` |
| **This brief** | `KasihKirimAndroid/` — **native Kotlin / Jetpack Compose / Supabase Kotlin SDK 3.5.0** |

These are mutually exclusive. `KasihKirimAndroid/` does not exist. The existing scaffold has ~8 screens, an SQLite outbox with birth-time idempotency keys, brand tokens and Zod schemas shared with the Edge layer.

**This is a decision, not a detail.** Three options:

| | Consequence |
|---|---|
| **A. Native Kotlin, retire Expo** | Follows the brief. Discards the offline outbox and shared Zod validation; both must be rebuilt in Kotlin. |
| **B. Keep Expo** | Preserves existing work and the shared-schema property. Contradicts the brief. |
| **C. Native Kotlin, port the outbox deliberately** | Highest cost, keeps the one piece that is genuinely hard to rebuild. |

I have **not** deleted `apps/mobile/`. Confirm before Phase 1 — this determines whether the offline architecture in `docs/ARCHITECTURE.md` §9 survives.

### 0.2 Backend baseline — your evidence, not mine

You report **9 files / 96 tests / 0 failures / PASS**. That matches the 96 assertions in this repo exactly, so I accept it as your runtime observation.

**I have never executed it.** My sandbox has no Docker, Postgres, Supabase CLI or Android SDK. Migrations `0009`–`0011` and the `0011` alias fix are, from my side, statically validated only. Your CI is the authority here, not me.

---

## 1. Current architecture

```
Android (to build)          ← Kotlin/Compose, publishable key only
   │  PostgREST + RPC + Auth
   ▼
Supabase
   ├── public   (65 RLS policies, 48 tables client-visible)
   ├── authz    5 JWT helpers, NOT PostgREST-exposed
   ├── internal ledger/payments/payouts — UNREACHABLE by any client JWT
   ├── audit    append-only, unreachable
   └── ref      reference data, read-only to authenticated
```

12 migrations · 85 tables · 29 enums · 65 policies · 4 Edge Functions · 96 assertions.

---

## 2. Backend capabilities — the real contract

**Android may call exactly these seven RPCs.** Anything else is a hallucinated contract.

| RPC | Returns | Parameters (exact) |
|---|---|---|
| `rpc_quote_kirim` | `jsonb` | `p_kirim_type TEXT, p_category_slug TEXT, p_est_weight_grams INT, p_origin_node UUID, p_dest_node UUID, p_budget_cap_sen BIGINT=0, p_volume_cm3 INT=8000, p_handling_flags TEXT[]='{}', p_payment_method TEXT='COD'` |
| `rpc_accept_offer` | `jsonb` | `p_trip UUID, p_kirim UUID, p_idempotency_key TEXT=NULL` |
| `rpc_delivery_transition` | `jsonb` | `p_delivery UUID, p_event TEXT, p_idempotency_key TEXT=NULL, p_meta JSONB='{}'` |
| `rpc_check_serviceability` | `jsonb` | `p_origin_node UUID, p_dest_node UUID` |
| `rpc_my_earnings` | `jsonb` | none |
| `rpc_send_capacity_invite` | `jsonb` | `p_trip UUID, p_audience TEXT, p_community UUID, p_target UUID, p_message TEXT` |
| `rpc_buy_from_lot` | `jsonb` | `p_lot UUID, p_qty NUMERIC, p_idempotency_key TEXT` |

**`service_role` only — Android must never reference these:** `rpc_apply_payment_event`, `rpc_record_webhook`, `rpc_idem_lookup`, `rpc_idem_store`, `rpc_consume_nonce`, `rpc_risk_signal`, `rpc_reconcile`, `custom_access_token_hook`.

### 2.1 Enums Android must mirror, not invent

`kirim_status` has **20** values — `DRAFT, POSTED, MATCHED, PROCURING, AWAITING_PICKUP, PICKED_UP, IN_TRANSIT, AT_HUB, OUT_FOR_DELIVERY, DELIVERED, COMPLETED, FAILED_PICKUP, FAILED_DELIVERY, PROCUREMENT_FAILED, RETURNING, RETURNED, CANCELLED, EXPIRED, DISPUTED, REFUNDED`.

**The brief's illustrative `DRAFT → POSTED → ACCEPTED → PICKED_UP → IN_TRANSIT → DELIVERED` is not the backend.** There is no `ACCEPTED`; the real successor to `POSTED` is `MATCHED`, and `BELI` inserts `PROCURING` before pickup. §30 says follow the backend — this plan does.

`vehicle_type`: `MOTORCYCLE, CAR, PICKUP, FOURWD, VAN, LORRY, **BOAT**` — BOAT is a peer, not a special case.
Also: `trip_status` (8), `order_status` (14), `payment_status` (16), `payment_method` (9), `district_status` (5), `lot_status` (6), `compliance_status` (7), `handling_flag` (8), `user_role` (9).

### 2.2 JWT claims

`app_metadata` carries `roles[]`, `carrier_id`, `seller_id`, `account_status`. Android reads these **for navigation only**. Authorization is RLS.

### 2.3 Geography — five outcomes, all from `rpc_check_serviceability`

`serviceable:true` · `DESTINATION_NOT_ACTIVE` · `ORIGIN_NOT_ACTIVE` · `NO_ROUTE` · `GEOGRAPHY_UNKNOWN`.

Android renders whichever the server returns. No district list in Kotlin, ever.

### 2.4 Money

50 `BIGINT` sen columns. `internal` is **not** PostgREST-exposed and the ledger has `UPDATE`/`DELETE` revoked from every role. Android **cannot** touch money even if it tried — it displays `rpc_my_earnings`. Use `Long` sen; format only at the UI edge.

---

## 3. Missing capabilities

| Gap | Impact | Action |
|---|---|---|
| **No SMS provider in `config.toml`** | Phone OTP cannot work. `[auth.sms]` has a template but no `[auth.sms.twilio]` block. | Phase 1 ships **email/password**. Phone UI stays dark until a provider is provisioned — §14. |
| No `rpc_create_kirim` | Customer cannot submit a Kirim | **Backend work first**, then Android |
| No `rpc_my_kirims` / board listing | Board and Orders have no source | PostgREST + RLS may suffice; verify before adding an RPC |
| No `rpc_create_trip` | Carrier cannot announce | Backend work |
| No storage buckets provisioned | POD photos, KYC | Phase 6 |
| `KasihKirimAndroid/` absent | — | Phase 1, pending §0.1 |

**Per §2 and §28: each gap gets a migration + tests + RLS verification before any Kotlin calls it.**

---

## 4. Dependency map

```
Auth (email/pw) ─► Profile/roles ─► Geography (nodes, serviceability)
                                          │
                        ┌─────────────────┴─────────────────┐
                   Customer Kirim                      Carrier trips
                   (needs rpc_create_kirim)            (needs rpc_create_trip)
                        └──────────► Matching ◄────────────┘
                                  rpc_accept_offer
                                        │
                              rpc_delivery_transition
                                        │
                            Money (rpc_my_earnings, read-only)
                                        │
                        Muatan Jual — behind compliance_status
```

---

## 5. Phases

| # | Phase | Gate |
|---|---|---|
| 1 | Foundation: Gradle, Compose, client, email auth, session restore, 5-tab nav | `assembleDebug` succeeds; APK installs; login/logout/relaunch verified **on a device** |
| 2 | Profile, roles from JWT, addresses, Sabah geography pickers | Role-aware nav; geography from backend |
| 3 | Customer Kirim — **backend `rpc_create_kirim` first** | Quote from `rpc_quote_kirim`; no client pricing |
| 4 | Carrier: vehicles incl. BOAT, trips, capacity | Paitan boat route selectable |
| 5 | Matching via `rpc_accept_offer` | Capacity refusal surfaces correctly |
| 6 | Delivery via `rpc_delivery_transition` + proofs | Idempotency keys on every transition |
| 7 | Money — display only | No mutation path exists in the client |
| 8 | Muatan Jual — UI reflects `compliance_status` | Never offers a transaction the backend will reject |
| 9 | Full Sabah geography | All five serviceability states rendered |
| 10 | Hardening, R8, signing, Play prep | Security audit §32 |

---

## 6. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **Expo/native conflict unresolved** | **High** | Blocks Phase 1. See §0.1. |
| Offline outbox lost in a stack switch | High | Port deliberately, or accept online-only and say so |
| Phone OTP promised in UI without a provider | High | Email-only until provisioned |
| Inventing an RPC that does not exist | High | The seven in §2 are the whole surface |
| Using the brief's example state machine | Medium | 20 real statuses; no `ACCEPTED` |
| Money in `Double` | High | `Long` sen throughout |
| Hardcoded district list | Medium | Geography from `ref.districts` / RPC only |
| **AGP 9.4.0 / Gradle 9.6.0 / compileSdk 37** | Medium | Beyond my knowledge cutoff. Will verify on first build; if a version does not resolve I will report rather than silently downgrade. |

---

## 7. Security plan

Publishable key only, from `local.properties`, never committed. No `service_role`, no DB password, nothing in `BuildConfig` beyond the public key and URL. One shared client, PKCE, deep link `kasihkirim://auth/callback`. No Supabase calls in Compose. Never log tokens or OTPs. RLS is the authorization boundary; JWT claims drive navigation only.

---

## 8. Testing plan

Backend: `supabase test db` after every migration — **must stay ≥ 9 files / ≥ 96 assertions / 0 failures**.
Android: ViewModel tests (state machines, error mapping), repository tests against a local stack, Compose UI tests for auth + Kirim + carrier, and a manual device pass per §24.

---

## 9. Release plan

Debug APK → device verification → R8 + signing → AAB → Play internal track. `applicationId` `com.ftechsolutions.kasihkirim`. Signing secrets in CI only.

---

## 10. Environmental limitation

I cannot run Gradle, adb, an emulator, Docker or the Supabase CLI in this environment, and there is no package-registry egress. I can write and statically review code; **I cannot produce a verified APK here**. Build verification must run on your machine or in CI, and I will not claim a build succeeded that I did not observe.
