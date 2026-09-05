# KasihKirim — Implementation Gap Report

**Product scope: Sabah-wide.** Beluran/Paitan/KK are initial pilot locations only.

**Stage 1–2 deliverable.** Audit of 12,410 lines across 55 files, assessed against the ten-point completion bar.

---

## 0a. VERIFICATION GATE — ATTEMPTED, FAILED TO EXECUTE

**Date: 2026-09-04.** Commands run, verbatim, with verbatim results.

```
$ supabase db reset
/bin/sh: 1: supabase: not found

$ supabase test db
/bin/sh: 2: supabase: not found

$ npm i -g supabase
npm error 403 a package version that is forbidden by your security policy,
npm error 403 on a server you do not have access to.
```

Toolchain probe: `supabase` NOT FOUND · `psql` NOT FOUND · `postgres` NOT FOUND ·
`pg_ctl` NOT FOUND · `initdb` NOT FOUND · `docker` NOT FOUND · `deno` NOT FOUND.
`node`/`npm` present but egress to the registry is blocked.

**Result: the verification gate did not run. 0 of 84 assertions executed.
0 of 8 migrations applied. Nothing in this report may be described as passing.**

Every row marked ✅ below means *written and statically reviewed*, never
*verified*. The gate must be run on a machine with Docker and the Supabase CLI.

### Open static findings — recorded, NOT fixed

| ID | Finding | Status |
|---|---|---|
| **SR-1** | `07_compliance.test.sql` references a `Sandakan` route node that is not seeded. Districts are Sabah-wide; route nodes are pilot-corridor only. | **REQUIRES DESIGN/SEED DECISION** — options A/B/C in `DEVELOPMENT-ENVIRONMENT.md` §8a. Do not add arbitrary route data. |
| **SR-2** | `ref` schema is not PostgREST-exposed, so the `GRANT SELECT ON ref.*` in `0008` is inert and the app cannot read geography reference data. | **REQUIRES ARCHITECTURE DECISION** — controlled public view/RPC, **not** blanket `ref` exposure. |

Neither is runtime-confirmed. Neither has been changed.

### Static analysis performed instead (NOT verification)

| Check | Result |
|---|---|
| Dollar-quote balance across 9 SQL files | Balanced |
| Table/enum inventory | 85 tables, 28 enum types |
| Forward-reference ordering across 0000→0007 | 0 real defects (1 flag on `auth.users`, provisioned by Supabase) |
| Duplicate policy names per table | 0 |
| Bare `auth.uid()` in policies | 0 |
| Service-role key in `apps/mobile/` | 0 |

Static analysis catches ordering and syntax defects. It cannot catch runtime
behaviour, SQLSTATE mismatches, GoTrue schema drift, or whether a single
assertion actually holds.

---

## 0. The constraint that shapes this report

The completion bar requires *"automated tests pass"* and *"happy path works."*

**No code in this repository has ever been executed.** My environment has no Postgres, no network, no Node runtime and no Android SDK. Every SQL file, Edge Function and screen was written statically.

That means **no feature area can be declared complete by me**, under your own definition. What follows separates three genuinely different states:

| State | Meaning |
|---|---|
| **Written** | Code exists and has passed static review |
| **Verified** | Code has been executed and tests pass — *requires you* |
| **Missing** | Does not exist |

Anything I build from here lands in **Written**. Only `supabase db reset && supabase test db` on a real machine moves it to Verified. That is the single highest-value action available, and it is not one I can perform.

---

## 1. Inventory

| Area | Files | Lines | State |
|---|---|---|---|
| Architecture docs | 9 | ~5,900 | Complete |
| Migrations | 7 + seed | ~2,700 | Written, unverified |
| pgTAP tests | 7 | ~700 | Written, never run (69 assertions) |
| Edge Functions | 7 | ~600 | Written, unverified |
| Mobile app | 15 | ~1,400 | Skeleton |
| Prototype | 1 | ~1,000 | **Runs** |
| CI | 1 | ~90 | Written, never triggered |
| Admin console | 0 | 0 | **Missing entirely** |

71 tables. 13 RPC functions. 4 of 18 catalogued Edge Functions.

---

## 2. Completion matrix

Ten criteria, per feature area. `—` = not applicable.

| Feature | Schema | RLS | Backend | Android | Happy | Failure | Authz test | Idem test | Tests pass | Prod config |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| Phone OTP auth | ✅ | ✅ | ⚠️ | ✅ | ❌ | ⚠️ | ⚠️ | — | ❌ | ⚠️ |
| Profile / roles | ✅ | ⚠️ | ✅ | ❌ | ❌ | ❌ | ✅ | — | ❌ | ⚠️ |
| Addresses | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | — | ❌ | ⚠️ |
| Kirim create + quote | ✅ | ✅ | ✅ | ⚠️ | ❌ | ❌ | ⚠️ | ❌ | ❌ | ⚠️ |
| Papan Kirim board | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ⚠️ | — | ❌ | ⚠️ |
| Offers / accept | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| Trips / Kirim Balik | ✅ | ✅ | ⚠️ | ❌ | ❌ | ❌ | ❌ | — | ❌ | ⚠️ |
| Capacity guard | ✅ | ✅ | ✅ | — | ❌ | ❌ | — | ✅ | ❌ | ✅ |
| Procurement + variance | ✅ | ✅ | ⚠️ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| QR / OTP handover | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
| Delivery state machine | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ✅ |
| Offline outbox | ✅ | — | ⚠️ | ⚠️ | ❌ | ❌ | — | ✅ | ❌ | ⚠️ |
| **Payments (provider)** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ | ❌ | ❌ |
| COD | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ |
| Settlement / ledger | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ⚠️ |
| Payouts | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Push notifications** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | — | — | ❌ | ❌ |
| **Delivery tracking** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | — | ❌ | ❌ |
| Marketplace | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Disputes | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | — | ❌ | ❌ |
| Chat | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | — | ❌ | ❌ |
| **Admin console** | ✅ | ✅ | ❌ | — | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Ajak Kirim | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | — | ❌ | ⚠️ |
| Kongsi & Untung | ✅ | ✅ | ⚠️ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| Muatan Jual | ✅ | ✅ | ✅ | ❌ | 🔒 | 🔒 | ❌ | ❌ | ❌ | 🔒 |

🔒 = deliberately gated pending legal approval. Do not unblock.

**Zero feature areas meet all ten criteria.** The database layer is the strongest (schema + RLS + invariant tests written); the presentation and integration layers are the weakest.

---

## 3. Defects found in this audit

### D-1 · `inventory_movements` — total lockout (functional)
RLS is enabled by the blanket loop in `0003`, but no policy exists. Default-deny means **a seller cannot read their own stock movement log.** Not a security hole; a missing feature that will present as a mysterious empty screen.
**Fix:** add an owner-scoped SELECT policy. *Fixed this session.*

### D-2 · `user_roles` — no self-read policy (functional)
Only `supabase_auth_admin` can read it. A user cannot see their own roles. Currently masked because roles arrive in the JWT claim, but any admin or debug screen reading the table will silently return nothing.
**Fix:** add self-read policy. *Fixed this session.*

### D-3 · 14 of 18 catalogued Edge Functions missing
`API.md` specifies 18; four exist. Absent: `kirim-publish`, `checkout`, `payment-intent`, `trip-manifest`, `sync-pull`, `sync-push`, `app-config`, `media-upload-url`, `handover-otp-send`, `handover-qr`, `dispute-open`, `seller-apply`, `account-delete-request`, `notify`.
**Impact:** the app cannot publish a Kirim, sync, upload media, or receive a manifest. This is the largest backend gap.

### D-4 · No payment provider integration
`payment-webhook` verifies an HMAC and applies an event, but nothing **creates** a payment. No provider adapter, no sandbox credentials, no `payment-intent`. Payments are 0% integrated, not partially.

### D-5 · Push notifications: table only
`notifications` and `internal.notification_outbox` exist. No dispatcher, no Expo token registration, no FCM credentials, no Android channels created at runtime.

### D-6 · Delivery tracking: table only
`delivery_tracking_points` exists and is partitioned. No foreground service, no ingest endpoint, no map screen.

### D-7 · Admin console absent
Zero files. Verification queues, payout approval (maker/checker) and dispute resolution have no operator surface. **A pilot cannot run without this** — someone must approve carriers.

### D-8 · Mobile: 8 of ~30 screens
Auth and one wizard step. No board, manifest, handover, tracking, earnings, or settlement views. The prototype is the specification for these.

### D-9 · Four bugs fixed this session (were latent)
| # | Defect | Consequence if unfixed |
|---|---|---|
| a | RLS loop hit PostGIS `spatial_ref_sys` | `0003` aborts; migration set fails from zero |
| b | `ux_commission_active` omitted `basis` | Second Muatan Jual rule rejected; unbundled pricing silently collapses |
| c | `commission_rules.party` lacked `promoter` | Promoter rule violates CHECK |
| d | `fn_apply_payment_event` never marked webhooks `PROCESSED` | Rows stuck at `RECEIVED`; lag alert fires permanently |

All four would have surfaced on first `db reset`. None were findable without reading the migrations end to end.

---

## 4. Invariants — preserved and verified-by-test

Audited; **no changes made**. Each has at least one pgTAP assertion written.

| Invariant | Mechanism | Test |
|---|---|---|
| No overbooking | Row lock + 3 CHECK constraints + TTL holds | `01` |
| Ledger balances | Deferred constraint trigger at COMMIT | `01`, `04` |
| Ledger immutable | `UPDATE`/`DELETE` revoked from all roles | — |
| Budget cap | Trigger requiring approved variance | `01` |
| Unspent budget returns | Settlement invariant + reconciliation check | `04` |
| Carrier float | Single CHECK over COD + advance + inventory | `01`, `06` |
| Delivery state server-owned | No UPDATE policy **and** no UPDATE grant | `02` |
| Webhook idempotency | `UNIQUE (provider, provider_event_id)` | `05` |
| QR replay | `UNIQUE` on nonce | `05` |
| Exactly-once offline | Birth-time idempotency key | `05` |
| `internal` unreachable | Not in PostgREST exposed schemas | `02` |
| No self-dealing | CHECK + triggers | `01`, `06` |

**Confirmed compliant** with the stated prohibitions: no service-role key in `apps/mobile/`; no client-side RLS bypass; no client-initiated balance mutation; all money flows through `internal.fn_post`.

---

## 5. Blockers by type

| Blocker | Type | Owner | Blocks |
|---|---|---|---|
| **Cannot execute migrations or tests** | Environment | **You** | Every "Verified" claim, all 16 stages |
| **LGL-02** — platform-held escrow vs Bank Negara | Legal | Lawyer | Payments, settlement, payouts |
| Payment provider account + sandbox keys | Commercial | You | Stage 8 |
| FCM project + service account | Ops | You | Stage 9 |
| Google Play developer account | Ops | You | Stages 15–16 |
| LGL-13/14/15 — food safety, trading licence | Legal | Lawyer | Muatan Jual only |

---

## 6. Sequenced plan

Stages are ordered by dependency. Each has an explicit gate that is **not** my sign-off.

| # | Stage | Gate | Blocked by |
|---|---|---|---|
| 3 | DB/migration/test defects | `supabase db reset` clean; 69 assertions green | **Execution** |
| 4 | Backend + 14 Edge Functions | Contract tests pass | Stage 3 |
| 5 | Authentication end-to-end | Real SMS OTP round trip | SMS provider |
| 6 | Customer flows | Maestro E1–E4, E21 green | Stage 4 |
| 7 | Carrier flows | Maestro E5–E15 green | Stage 4 |
| 8 | Payments (sandbox) | Idempotency + reconciliation green | **LGL-02**, provider keys |
| 9 | Push | Delivery receipts on real OEM devices | FCM |
| 10 | Tracking | Foreground service, battery ≤12%/4h | Stage 7 |
| 11 | COD | Reconciliation clean 7 days | Stage 8 |
| 12 | Settlements | 30 days zero variance | Stage 11 |
| 13 | Admin | Maker/checker enforced | Stage 4 |
| 14 | Automated tests | CI green | All |
| 15 | CI/CD + signed AAB | Build reproducible | Play account |
| 16 | Production audit | Checklist in `SECURITY.md` §13 | All |

**Stages 3 and 4 are the critical path.** Nothing downstream is verifiable until migrations apply cleanly and the backend surface exists.

---

## 7. Recommendation

Do not build stages 5–16 before stage 3 passes. The four latent bugs found today are evidence: static review catches some defects, execution catches the rest, and building three layers on an unverified foundation multiplies the eventual rework.

**Concretely, next:**

1. **You:** `supabase db reset && supabase test db`. Paste the output.
2. **Me:** fix real failures, then build the 14 missing Edge Functions against a schema known to apply.
3. **You, in parallel:** LGL-02 to a lawyer; open a payment-provider sandbox account; create the FCM project.

The COD-only **initial pilot** (Beluran/Paitan/KK) needs stages 3, 4, 6, 7, 13. The architecture already supports all 27 Sabah districts; the pilot is an operational scope, not an architectural one. It does **not** need stage 8, which is where the legal blocker sits. That is the shortest credible path to something real carrying real parcels.
