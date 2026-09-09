# KasihKirim — Deployment & Release

GitHub · Supabase · Vercel · Native Android (Kotlin/Gradle) · Google Play

> **Native build note (added Phase 10).** `CLAUDE_IMPLEMENTATION_PLAN.md` §0.1
> chose **native Kotlin** (`KasihKirimAndroid/`) over the Expo/React Native
> app this document was written for. As of this note both still physically
> exist in the repo (`apps/mobile/` hasn't been deleted), so treat every
> **mobile-specific** claim below as describing the *retired* stack unless a
> section explicitly says otherwise. Sections §1–§7 and §9–§15 that describe
> Supabase, the admin console, migrations, secrets rotation, and Play policy
> in general are stack-agnostic and were not re-verified in this pass.
> §8 (EAS) and §10.2 (API levels) are corrected below with values read
> directly from `KasihKirimAndroid/app/build.gradle.kts`. §12's Sentry row
> and §16's OTA/Expo-SDK rows do not apply to the native build — there is no
> crash-reporting SDK and no OTA-update mechanism in `KasihKirimAndroid/`
> today. See `docs/RELEASE_SIGNING.md` for the native build's actual signing
> and CI pipeline.

---

## 1. Environments

| Env | Supabase | Vercel | Mobile (native build) | Data |
|---|---|---|---|---|
| **local** | Supabase CLI (Docker) | `next dev` | Android Studio / `adb install`, `local.properties` pointed at whichever Supabase project you're testing against | Seed fixtures |
| **dev** | `kasihkirim-dev` | Preview | `android-cloud-build.yml` debug APK, downloaded as a CI artifact | Synthetic |
| **staging** | `kasihkirim-staging` | Preview (protected) | Same debug APK pipeline, sideloaded for internal testing — no distinct "preview" build type exists | Synthetic, production-shaped |
| **production** | `kasihkirim-prod` | Production | `android-release-build.yml` signed AAB → manual Play Console upload (§8, §10.6) | Real |

The Supabase/Vercel columns above were not re-verified in this pass — only
the Mobile column, which is squarely this document's Android scope, was
corrected. Whether `kasihkirim-dev`/`-staging`/`-prod` actually exist as
separate projects, and which one `KasihKirimAndroid/`'s CI secrets
currently point at, wasn't checked.

**Separate Supabase projects per environment**, not separate schemas. Shared-project separation eventually leaks — one mistaken connection string and a test writes to production. Separate projects make that impossible rather than unlikely.

**Production data is never copied downward.** Staging is seeded with generated data shaped like production. This is a PDPA requirement (`SECURITY.md` §11) and prevents the common failure of a developer debugging against a real person's MyKad.

---

## 2. Repository

Single repository, npm workspaces. Small team, tightly coupled contracts — a polyrepo would mean versioning the type definitions between the app and the database, which is pure overhead at this size.

```
kasihkirim/
├── apps/
│   ├── mobile/              Expo — retired per CLAUDE_IMPLEMENTATION_PLAN.md §0.1,
│   │                        still physically present in the repo, not deleted
│   └── admin/               Next.js (not re-verified in this pass)
├── KasihKirimAndroid/       Native Kotlin/Compose — the app that actually ships
├── packages/                Not re-verified in this pass
├── supabase/
│   ├── migrations/          Timestamped, forward-only
│   ├── functions/           Edge Functions (Deno)
│   ├── seed.sql             Single file, not a seed/ directory
│   └── tests/                pgTAP
├── docs/                    This document set
└── .github/workflows/       android-cloud-build.yml, android-release-build.yml
                              (see docs/RELEASE_SIGNING.md), plus whatever
                              covers Supabase/admin CI (not re-verified here)
```

The `packages/`, `apps/admin/`, and `e2e/` rows in the original tree could
not be confirmed to exist as described in this pass — this document's
Android-facing claims were checked against the actual repository; its
Supabase/Next.js/e2e claims were not.

`shared-schemas` matters more than it looks: the same Zod schema validates a Kirim on the phone and again in the Edge Function. Client validation is UX; server validation is the control. One definition prevents them drifting.

---

## 3. Branching

Trunk-based. `main` is always releasable.

```
feature/kirim-beli-variance ──┐
                              ├──► main ──► staging (auto) ──► production (tagged)
fix/otp-rate-limit ───────────┘
```

- Short-lived branches, squash merge.
- `main` protected: PR required, 1 approval, all CI gates green, linear history.
- **Migrations and money-path changes require a second reviewer** with database or finance context.
- Release tags `v1.4.0`; hotfix branches from the tag.

---

## 4. CI/CD

### 4.1 Pull request

```yaml
# .github/workflows/pr.yml
jobs:
  quality:        # typecheck, lint, RLS-policy lint ((SELECT auth.uid()))
  unit:           # Vitest — 95% on money/state modules
  database:       # supabase start → migrate → pgTAP → RLS matrix
  edge:           # deno test
  integration:    # against the local stack
  payload-budget: # every catalogued endpoint vs API.md §6
  security:       # semgrep, gitleaks, npm audit
```

The `database` job is the slowest and the most valuable. It boots real Postgres, applies every migration from zero, and runs the full RLS matrix. It catches the class of bug that would otherwise reach production as a data breach. (This whole block was not re-verified against the actual `pr.yml` in this pass — only the `build-check` row was, and it's removed here because it doesn't exist: Android CI runs as its own separate workflow, `.github/workflows/android-cloud-build.yml`, not as a job inside `pr.yml`. It runs `./gradlew test` + `:app:assembleDebug` + two forbidden-secret gates, not `expo prebuild`. See §8.1.)

### 4.2 Merge to `main`

```yaml
jobs:
  migrate-staging:    supabase db push --project-ref $STAGING
  deploy-functions:   supabase functions deploy --project-ref $STAGING
  deploy-admin:       vercel deploy (staging)
  # android-cloud-build.yml already runs on every push to main on its own
  # trigger (push: branches: [main]) -- it isn't a job inside this pipeline,
  # and it produces a debug APK artifact, not a staging/internal-track build.
  e2e:                maestro test e2e/ (not re-verified in this pass)
  smoke:              staging health checks
```

### 4.3 Production release

Manually triggered, tagged, and gated on a human approval in a GitHub Environment
for the Supabase/admin side. The native Android release is **not** part of
this pipeline at all: `android-release-build.yml` is its own
`workflow_dispatch`-only workflow (§8.1), run separately, whenever a signed
AAB is actually wanted — there is no auto-build-and-submit-on-tag step for
mobile today, and no staged-rollout automation (§10.6's staged rollout is a
manual Play Console action).

```yaml
jobs:
  approval:           # GitHub Environment protection rule
  backup:             # on-demand Supabase backup before migration
  migrate-prod:
  deploy-functions:
  deploy-admin:
  # Mobile release is a separate, manually-dispatched workflow -- see above.
  monitor:            # crash rate, payment failures, reconciliation
                       # (mobile crash-rate monitoring specifically: not
                       # wired up yet, per §12)
```

---

## 5. Database migrations

### 5.1 Rules

1. **Forward-only.** No destructive down migrations in production. A mistake is fixed by a new migration.
2. **Expand / contract** for every column change: add nullable → backfill → dual-write → switch reads → drop old. Never rename in one step.
3. **Every migration ships its RLS policies.** A table without policies fails CI.
4. `CREATE INDEX CONCURRENTLY` on populated tables.
5. **No long backfill inside a migration.** Backfills are separate, resumable, batched jobs.
6. **Financial tables are append-only in migrations too.** A migration that would `UPDATE internal.ledger_entries` is rejected in review, without exception.

### 5.2 Zero-downtime sequence

```
Release N     add nullable column + policies; deploy code that WRITES both
Release N+1   backfill job runs to completion; verify
Release N+2   switch reads to the new column
Release N+3   drop the old column
```

Slow on purpose. The mobile client is the constraint: a rural user may be on a build from three months ago, and the schema must serve both that build and the current one. **The database can never move faster than the oldest supported app version.**

### 5.3 Pre-production rehearsal

Every migration is applied to a PITR restore of production before it reaches production. Timing is measured; anything holding a lock beyond 5 s is rejected and reworked.

---

## 6. Edge Functions

```bash
supabase functions deploy delivery-transition --project-ref $REF --no-verify-jwt=false
supabase secrets set --project-ref $REF --env-file .env.production
```

- Secrets from GitHub Environments → Supabase secrets. **Never in the repository.**
- The webhook function is the only one deployed with `--no-verify-jwt` — it authenticates by HMAC signature instead (`API.md` §4.12).
- Deployed in dependency order; functions are versioned with the release tag for traceability.
- Cold start is managed by keeping money-path functions small and import-light.

---

## 7. Admin console (Vercel)

| Setting | Value |
|---|---|
| Framework | Next.js App Router |
| Production branch | `main`, tagged deploys |
| Preview | Every PR, **Deployment Protection on**, staging Supabase only |
| Env vars | `SUPABASE_SERVICE_ROLE_KEY` server-side only — never `NEXT_PUBLIC_*` |
| Headers | HSTS, CSP, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer` |
| Regions | Singapore (`sin1`) — closest to Sabah |

A CI check greps the client bundle for the service-role key pattern. A leak there is total compromise, so it is checked mechanically rather than trusted to review.

---

## 8. Mobile — native build (Kotlin/Gradle/GitHub Actions)

**This section describes `KasihKirimAndroid/` as it actually builds today.**
There is no EAS profile system, no `eas.json`, and no OTA channel — see §16
for what that means for how a fix ships.

### 8.1 Build pipelines

| Pipeline | File | Trigger | Produces |
|---|---|---|---|
| PR / main CI | `.github/workflows/android-cloud-build.yml` | `push` to `main`, every PR, manual | Debug APK, R8-shrunk but unsigned release build type exercised, two forbidden-secret gates |
| Release | `.github/workflows/android-release-build.yml` | `workflow_dispatch` only, never a push or PR | Signed release **AAB** (`:app:bundleRelease`) |

Both jobs run the same `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY`-from-secrets
step and the same forbidden-secret source gate; the release pipeline adds a
second gate that scans the *extracted* AAB contents, and needs four more
secrets (`RELEASE_KEYSTORE_BASE64`, `RELEASE_KEYSTORE_PASSWORD`,
`RELEASE_KEY_ALIAS`, `RELEASE_KEY_PASSWORD`) the PR pipeline doesn't. See
`docs/RELEASE_SIGNING.md` for exactly what those are and how to generate
them.

**No iOS.** There never was an iOS target for the native build; Android-only
is still the scope decision, it's just no longer expressed as "no iOS EAS
profile" since EAS itself doesn't apply.

Production ships an **AAB** (`:app:bundleRelease`), so Play generates
per-ABI splits — the `PRD.md` NFR-101 25 MB budget still applies and hasn't
been re-measured against the native build's actual APK/AAB size in this
pass.

### 8.2 Credentials

- Whether to enrol in **Play App Signing** (Google holds the app signing
  key; you upload with a separate, replaceable upload key) is a Play
  Console decision at first upload — `RELEASE_SIGNING.md` doesn't presume
  either way, and neither does this document.
- The release keystore is generated and held by whoever runs
  `docs/RELEASE_SIGNING.md`'s `keytool` command — not EAS credentials,
  since there is no EAS. Same principle as the old row below: losing all
  four `RELEASE_KEYSTORE_*`/`RELEASE_KEY_*` values means losing the
  ability to ship an update to the same `applicationId` ever again, so they
  belong in a password manager, not only in GitHub Actions secrets.
- No Play service account JSON exists in this repository's secrets yet —
  `android-release-build.yml` produces an artifact for **manual** upload,
  it does not call the Play Publishing API. Automating that needs a
  service-account JSON this repository hasn't been given, and wasn't asked
  to add.

Losing the upload key is recoverable through Play support; losing it *and*
having no record of which key was used is not. It is documented in the
runbook.

---

## 9. OTA updates — does not apply to the native build

Everything below this heading described `expo-updates`: a JS bundle
downloaded and swapped without a Play Store review, possible because an
Expo/React Native app's logic mostly lives in an interpreted JS bundle
separate from the compiled native shell. `KasihKirimAndroid/` is a compiled
Kotlin APK/AAB with no such split — **there is no mechanism in this
repository today for shipping a fix without a new Play build.** No
Firebase Remote Config, no custom update channel, nothing has been
substituted for it; this is a real gap relative to the plan this document
was originally written against, not a documented equivalent.

**What this means in practice:** every bug fix, copy change, and feature
ships through the same path — `android-release-build.yml` → a new signed
AAB → Play Console upload → staged rollout (§10.6). A typo in a string
resource takes exactly as long to ship as a new screen. If shipping small
fixes without a full review cycle turns out to matter for this product,
that's a build to scope deliberately (e.g. Play's own in-app update API for
prompting a refresh, or a server-driven config/feature-flag layer for the
subset of behavior that's safe to toggle remotely) — not something to
assume is already covered.

Rollback for a bad native release is the same as before: halt the Play
staged rollout and let it fall back to the last version already at 100%
(§10.6). There is no `eas update:rollback` equivalent because there is no
OTA layer for it to roll back.

---

## 10. Google Play release process

### 10.1 One-time setup

| Item | Value / note |
|---|---|
| Developer account | **Organisation account.** Also exempts from the 12-tester / 14-day closed-testing requirement that applies to new personal accounts. |
| Package name | `com.ftechsolutions.kasihkirim` — decided; permanent, cannot ever be changed. This section otherwise predates the native-Kotlin pivot (see the scope note at the top of this document and `docs/RELEASE_SIGNING.md`) and still needs a full native-build pass. |
| App signing | Play App Signing enabled |
| Category | Business, or Shopping |
| Content rating | IARC questionnaire; expect 3+ / PEGI 3 with a commerce declaration |
| Target audience | 18+ (financial transactions) |
| Ads | None |
| **Financial features** | **Declared.** Physical goods and real-world services must **not** use Play Billing — external payment is correct and permitted here (`PRD.md` LGL-05) |
| Account deletion URL | `https://kasihkirim.com/delete-account` — publicly reachable, required |
| Privacy policy URL | `https://kasihkirim.com/privacy` — BM and English |

### 10.2 API level requirements

**Actual values, read from `KasihKirimAndroid/app/build.gradle.kts`** (this
table previously stated 24/36/36, which doesn't match what's shipped):

| Setting | Planned (this doc, originally) | Actual (`build.gradle.kts`) |
|---|---|---|
| `minSdk` | 24 (Android 7.0) | **26** (Android 8.0) |
| `targetSdk` | 36 (Android 16) | **37** |
| `compileSdk` | 36 | **37** |

**`minSdk` is a real discrepancy worth a decision, not just a docs fix.**
This document's stated reason for 24 — "covers the old budget devices in
the target market" — is a product requirement, and 26 silently narrows
that: any Android 7.0/7.1 device (API 24–25) in the Sabah target market
cannot install this app as it stands. This may have been a deliberate
Phase 1 engineering call (a dependency or language feature needing 26+) or
an oversight; either way it wasn't re-confirmed against the original
product requirement when set, and rechecking that against actual budget
Android device data for Sabah is a business decision, not something to
silently resolve either direction here.

**16 KB page size** — every native library must support 16 KB page
alignment for updates to apps targeting Android 15+ from 1 February 2027,
and `targetSdk = 37` is already well past that threshold. **No CI check
for this exists yet** in either `android-cloud-build.yml` or
`android-release-build.yml` — the `bundletool`/`check_elf_alignment.sh`
gate this document called for was never added. Worth adding before the
16 KB deadline, not discovered as a blocked release when it arrives.

### 10.3 Data Safety declaration

Must match what the app actually collects. Mismatches cause rejection and, worse, erode trust.

| Data | Collected | Shared | Purpose | Optional |
|---|---|---|---|---|
| Phone number | ✅ | ❌ | Account, delivery coordination | No |
| Name | ✅ | With counterparty | Delivery | No |
| **Precise location** | ✅ | With counterparty during delivery | Handover proof, tracking | No |
| Photos | ✅ | With counterparty | Products, POD, receipts, addresses | No |
| **Financial info** | ✅ | With payment provider | Payments, payouts | No |
| Government ID | ✅ | ❌ | Carrier/seller verification | Yes (carriers/sellers only) |
| Messages | ✅ | With counterparty | Delivery coordination | Yes |
| Device identifiers | ✅ | ❌ | Push, fraud prevention | No |
| Crash logs | ✅ | Sentry | Diagnostics | No |

All data encrypted in transit; deletion request path documented; retention exceptions for financial records disclosed honestly.

### 10.4 Permission declarations

| Permission | Declaration required |
|---|---|
| `ACCESS_FINE_LOCATION` | Prominent in-app disclosure before the first request; Data Safety entry |
| `FOREGROUND_SERVICE_LOCATION` | Foreground service type declared; visible notification |
| `ACCESS_BACKGROUND_LOCATION` | **Not requested.** Avoids the sensitive-permission review, the demo video, and the ongoing justification burden (`ARCHITECTURE.md` ADR-06) |
| `CAMERA` | In-context rationale |
| `POST_NOTIFICATIONS` | Primed in-context, not at cold start |
| Photo access | **Android Photo Picker** — no permission needed, no `READ_MEDIA_IMAGES` declaration |
| `READ_SMS` | **Never.** SMS Retriever API autofills OTP with no permission |

Avoiding background location and `READ_SMS` removes the two most common causes of extended Play review for apps in this category.

### 10.5 Store listing

Bahasa Malaysia primary, English secondary.

- Title: `KasihKirim — Kirim dengan Kasih`
- Short description: *Kirim dengan kasih, dari kampung ke bandar.*
- Screenshots captured on a **low-end device frame** — the listing should look like the product the target user will actually experience, not a flagship mockup.
- Feature graphic in the brand palette (deep forest green, gold, orange on cream).

### 10.6 Track progression

```
Internal (team, minutes)
   ↓  smoke tests pass
Closed — Beluran pilot cohort (6 weeks)
   ↓  pilot exit criteria met (TESTING.md §12)
Open testing (optional, wider Sabah)
   ↓
Production, staged: 5% → 20% → 50% → 100%
```

**Staged rollout gates.** Advance only if, over 24 h at the current stage:

| Metric | Halt threshold |
|---|---|
| Crash-free sessions | < 99 % |
| ANR rate | > 0.5 % |
| Payment failure rate | > 10 % |
| Ledger reconciliation | **any** variance |
| Support tickets | > 3× baseline |

`releaseStatus: inProgress` with `rollout: 0.05` means a bad release reaches 5 % of users, not all of them. Halting a rollout is a single Play Console action and takes effect immediately for users who have not yet updated.

### 10.7 Review expectations

- First submission: allow 3–7 days.
- Updates: usually hours to 2 days.
- **First submission with financial features and location will take the longest.** Submit the first production build well ahead of any launch commitment.
- Rejections are answered with a corrected build plus an explicit note on what changed — never a resubmission of the same binary with an appeal.

---

## 11. Secrets

| Secret | Stored in | Rotation |
|---|---|---|
| Supabase service role | GitHub Environments, Vercel (server) — the EAS entry no longer applies; not re-verified whether the native build's CI needs it at all (it shouldn't: only the publishable key is used, per `SupabaseClientProvider.kt`) | 6 months |
| Gateway API + webhook keys | Supabase secrets | Per provider policy |
| SMS/WhatsApp provider | Supabase secrets | 12 months |
| Ed25519 QR signing key | **Supabase Vault** | 12 months, dual-key window |
| OTP pepper | **Supabase Vault** | 12 months |
| Play service account | **Does not exist yet.** `android-release-build.yml` doesn't publish to Play — see §8.2 | — |
| Sentry DSN | N/A on mobile — no Sentry integration exists in `KasihKirimAndroid/` (§12) | — |
| Android release keystore | Held by whoever generates it per `docs/RELEASE_SIGNING.md`; `RELEASE_KEYSTORE_BASE64`/`RELEASE_KEYSTORE_PASSWORD`/`RELEASE_KEY_ALIAS`/`RELEASE_KEY_PASSWORD` in GitHub Actions secrets, not "EAS credentials" | Never |
| `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` (Android) | GitHub Actions secrets, read into `local.properties` at build time — public by design, not sensitive, but still not committed | N/A |

Rotation is scheduled work with a runbook, not an incident response. The QR key rotation specifically supports two active keys simultaneously, because a carrier may be holding a token issued before rotation and be out of coverage until after it.

---

## 12. Observability

**Mobile-specific note:** `KasihKirimAndroid/` has no crash-reporting SDK
of any kind today — not Sentry, not Play Vitals wiring, nothing (confirmed
by grepping the app's dependencies and sources). The Edge/Postgres/admin-
console side of this table was not re-checked in this pass and may still
be accurate; only the mobile row is confirmed stale.

| Signal | Tool | Alert |
|---|---|---|
| Crashes / ANR | **Not yet wired up on the native build.** Sentry + Play Vitals, below, describes the plan this table was originally written against. | Crash-free < 99 %; ANR > 0.4 % |
| Edge errors | Sentry + Supabase logs | > 2 % over 5 min |
| Payment failures | Custom metric | > 10 % over 15 min |
| Webhook lag | `received_at → processed_at` | p95 > 60 s |
| **Ledger imbalance** | Daily job | **Any variance → immediate page, halt payouts** |
| **Capacity constraint violation** | Postgres error counter | **Any occurrence → page** (means a bug reached layer 2) |
| Budget-cap trigger fires | Counter | Spike → fraud review |
| COD + advance exposure | Rolling sum | Above threshold |
| Voucher burn | Against campaign ceiling | 80 % consumed |
| Match rate / fill rate | Product metrics | Fill rate < 30 % — carrier economics at risk |
| Client outbox depth | Telemetry | p95 > 20 items — suggests a sync defect |
| DB connections / slow queries | Supabase metrics | Pool > 80 %; queries > 2 s |

`X-Request-Id` is generated on the phone, echoed through Edge and Postgres, attached to Sentry events and written to `audit_logs`. One identifier traces a tap in Kg Muasnad through to the gateway.

**Sentry scrubbing** is configured in `beforeSend`: no phone numbers, no NRIC, no coordinates, no tokens. Verified by a test that asserts a scrubbed payload.

---

## 13. Backup and disaster recovery

| Parameter | Value |
|---|---|
| PITR | Enabled, 7-day window |
| RPO | ≤ 5 minutes |
| RTO | ≤ 4 hours |
| Logical dumps | Nightly, encrypted, separate cloud account, 30-day retention |
| Storage buckets | Versioning on; nightly replication |
| **Restore drill** | **Quarterly**, timed, into a scratch project |

The restore drill is the only thing that turns a backup into a recovery capability. An untested backup is a belief, not a control.

| Scenario | Response |
|---|---|
| Bad migration | PITR to just before; replay verified migrations |
| Data corruption | PITR; reconcile ledger; notify affected users |
| Region outage | Supabase-managed failover; status page; COD keeps the network running |
| Gateway outage | Feature-flag prepaid off; COD only; in-app banner |
| Total project loss | Restore from logical dump into a new project; repoint DNS and app config |

---

## 14. Runbooks

Each is a separate document in `docs/runbooks/`, written to be followed at 3 a.m. by someone who did not build the system.

1. Ledger imbalance detected (**SEV-1** — halt payouts first, diagnose second)
2. Payment gateway outage
3. Webhook backlog
4. Overbooking constraint violation
5. SMS spend spike / suspected pumping
6. Bad release rollback (OTA and native)
7. Database restore from PITR
8. Key rotation (QR, OTP pepper, service role)
9. Carrier COD shortfall
10. Fraud ring response
11. Data subject access or deletion request
12. Play policy rejection

---

## 15. Release cadence

| Type | Cadence | Path |
|---|---|---|
| Feature / fix release | As needed — **every** change ships this way now, per §9 | `android-release-build.yml` → signed AAB → manual Play upload → staged rollout (§10.6) |
| Security hotfix | Immediate | Same path as above, expedited — there's no separate OTA channel to push it through faster |
| Android Gradle Plugin / Kotlin / Compose upgrade | As needed | `.github/dependabot.yml` (added Phase 10) opens PRs for Gradle dependency updates; still needs a human to actually review and merge them |

The "OTA fix" and "Expo SDK upgrade" rows from the original plan don't
translate to the native build (§9) — there is no OTA channel to push a fix
through faster than a full release, and no Expo SDK to stay a version
behind. What replaced the discipline those rows enforced (small team,
stability over being current) hasn't been decided for the native build;
this table should be revisited once there's real release history to base
a cadence on rather than inheriting the Expo-era numbers unchanged.

---

## 16. Launch checklist

**Infrastructure**
- [ ] Production Supabase provisioned; PITR on; extensions installed
- [ ] Migrations applied from zero and verified reproducible
- [ ] Beluran corridor, categories, pricing v1, commission (25 % of order total) seeded
- [ ] `pg_cron` jobs scheduled and confirmed running
- [ ] Storage buckets created with policies
- [ ] Secrets set; Vault keys generated
- [ ] Sentry, alerting and on-call rota live
- [ ] Backup verified by an actual restore

**Application**
- [ ] All CI gates green
- [ ] Pilot exit criteria met (`TESTING.md` §12)
- [ ] Security checklist complete (`SECURITY.md` §13)
- [ ] Penetration test findings closed

**Play**
- [ ] Organisation developer account verified
- [ ] Data Safety matches actual collection
- [ ] Financial features declared
- [ ] Privacy policy and account deletion URLs live, in BM and English
- [ ] Listing complete in BM and English
- [ ] Pre-launch report clean
- [ ] Staged rollout configured at 5 %

**Business / legal**
- [ ] **LGL-02 resolved** — platform-held escrow vs Bank Negara. *Blocking for prepaid payments; COD-only pilot may proceed without it.*
- [ ] LGL-01 courier licensing position determined
- [ ] Terms of service and carrier agreement published
- [ ] Support channel staffed, in Bahasa Malaysia
- [ ] Prohibited-goods list seeded
- [ ] Voucher campaign budget ceiling set against the RM 500k raise
