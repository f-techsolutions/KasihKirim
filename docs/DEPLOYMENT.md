# KasihKirim — Deployment & Release

GitHub · Supabase · Vercel · Expo EAS · Google Play

---

## 1. Environments

| Env | Supabase | Vercel | Mobile | Data |
|---|---|---|---|---|
| **local** | Supabase CLI (Docker) | `next dev` | Expo Dev Client | Seed fixtures |
| **dev** | `kasihkirim-dev` | Preview | EAS `development` | Synthetic |
| **staging** | `kasihkirim-staging` | Preview (protected) | EAS `preview` → internal track | Synthetic, production-shaped |
| **production** | `kasihkirim-prod` | Production | EAS `production` → Play | Real |

**Separate Supabase projects per environment**, not separate schemas. Shared-project separation eventually leaks — one mistaken connection string and a test writes to production. Separate projects make that impossible rather than unlikely.

**Production data is never copied downward.** Staging is seeded with generated data shaped like production. This is a PDPA requirement (`SECURITY.md` §11) and prevents the common failure of a developer debugging against a real person's MyKad.

---

## 2. Repository

Single repository, npm workspaces. Small team, tightly coupled contracts — a polyrepo would mean versioning the type definitions between the app and the database, which is pure overhead at this size.

```
kasihkirim/
├── apps/
│   ├── mobile/              Expo — Android only
│   └── admin/               Next.js
├── packages/
│   ├── shared-types/        Generated Supabase types + domain types
│   ├── shared-schemas/      Zod — validated identically on client and Edge
│   └── shared-config/       ESLint, TS, Prettier
├── supabase/
│   ├── migrations/          Timestamped, forward-only
│   ├── functions/           Edge Functions (Deno)
│   ├── seed/                Beluran corridor, categories, pricing v1
│   └── tests/               pgTAP
├── e2e/                     Maestro flows
├── docs/                    This document set
└── .github/workflows/
```

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
  build-check:    # expo prebuild --no-install; APK size gate
```

The `database` job is the slowest and the most valuable. It boots real Postgres, applies every migration from zero, and runs the full RLS matrix. It catches the class of bug that would otherwise reach production as a data breach.

### 4.2 Merge to `main`

```yaml
jobs:
  migrate-staging:    supabase db push --project-ref $STAGING
  deploy-functions:   supabase functions deploy --project-ref $STAGING
  deploy-admin:       vercel deploy (staging)
  build-mobile:       eas build -p android --profile preview
  submit-internal:    eas submit --track internal
  e2e:                maestro test e2e/ (floor + mid-range device)
  smoke:              staging health checks
```

### 4.3 Production release

Manually triggered, tagged, and gated on a human approval in a GitHub Environment.

```yaml
jobs:
  approval:           # GitHub Environment protection rule
  backup:             # on-demand Supabase backup before migration
  migrate-prod:
  deploy-functions:
  deploy-admin:
  build-mobile:       eas build -p android --profile production --auto-submit
  staged-rollout:     # Play: 5% → 20% → 50% → 100%
  monitor:            # crash rate, payment failures, reconciliation
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

## 8. Mobile — EAS

### 8.1 Build profiles

```json
{
  "build": {
    "development": {
      "developmentClient": true,
      "distribution": "internal",
      "android": { "buildType": "apk", "gradleCommand": ":app:assembleDebug" },
      "channel": "development"
    },
    "preview": {
      "distribution": "internal",
      "android": { "buildType": "apk" },
      "channel": "preview",
      "env": { "APP_ENV": "staging" }
    },
    "production": {
      "android": { "buildType": "app-bundle" },
      "channel": "production",
      "env": { "APP_ENV": "production" },
      "autoIncrement": "versionCode"
    }
  },
  "submit": {
    "production": {
      "android": {
        "serviceAccountKeyPath": "./play-service-account.json",
        "track": "production",
        "releaseStatus": "inProgress",
        "rollout": 0.05
      }
    }
  }
}
```

**No iOS profiles.** Android-only is a scope decision, and leaving iOS configuration in place invites accidental effort.

Production ships an **AAB**, so Play generates per-ABI splits and the download stays inside the 25 MB budget (`PRD.md` NFR-101).

### 8.2 Credentials

- **Play App Signing** enabled; Google holds the app signing key.
- Upload key held in EAS credentials, backed up offline in the founders' password manager.
- Play service account JSON in EAS secrets, never in the repository.

Losing the upload key is recoverable through Play support; losing it *and* having no record of which key was used is not. It is documented in the runbook.

---

## 9. OTA updates (EAS Update)

### 9.1 What may ship over the air

| Change | OTA | Store build |
|---|---|---|
| JS logic, copy, styling | ✅ | |
| New screen using existing native modules | ✅ | |
| Bug fix in an existing flow | ✅ | |
| Images, translations | ✅ | |
| New native module | | ✅ |
| **Permission change** | | ✅ |
| Expo SDK upgrade | | ✅ |
| `app.json` native config | | ✅ |
| **Anything altering payment behaviour** | | ✅ |

The last row is policy, not technical necessity. A change to how money is presented or taken should go through store review and staged rollout, not slip in silently overnight.

### 9.2 Update strategy for slow connections

```json
{
  "updates": {
    "enabled": true,
    "checkAutomatically": "ON_LOAD",
    "fallbackToCacheTimeout": 0,
    "url": "https://u.expo.dev/{project-id}"
  },
  "runtimeVersion": { "policy": "fingerprint" }
}
```

`fallbackToCacheTimeout: 0` is essential. It means the app **never blocks launch** waiting to download an update. On a 3G link in Beluran, a blocking update check is indistinguishable from a broken app. The update downloads in the background and applies on the next launch.

Updates are published per channel; `production` only after the same build has run clean on `preview`.

### 9.3 Rollback

```bash
eas update:rollback --channel production          # instant, JS-level
eas update:republish --group <previous-group-id>  # explicit known-good
```

Rollback takes effect on next app launch. For a bad **native** build, halt the Play rollout and resume the previous release.

---

## 10. Google Play release process

### 10.1 One-time setup

| Item | Value / note |
|---|---|
| Developer account | **Organisation account.** Also exempts from the 12-tester / 14-day closed-testing requirement that applies to new personal accounts. |
| Package name | `my.kasihkirim.app` — permanent, cannot ever be changed |
| App signing | Play App Signing enabled |
| Category | Business, or Shopping |
| Content rating | IARC questionnaire; expect 3+ / PEGI 3 with a commerce declaration |
| Target audience | 18+ (financial transactions) |
| Ads | None |
| **Financial features** | **Declared.** Physical goods and real-world services must **not** use Play Billing — external payment is correct and permitted here (`PRD.md` LGL-05) |
| Account deletion URL | `https://kasihkirim.com/delete-account` — publicly reachable, required |
| Privacy policy URL | `https://kasihkirim.com/privacy` — BM and English |

### 10.2 API level requirements

| Setting | Value | Note |
|---|---|---|
| `minSdkVersion` | **24** (Android 7.0) | Covers the old budget devices in the target market |
| `targetSdkVersion` | **36** (Android 16) | Google Play requires new apps to target API 36 as of 31 August 2026 |
| `compileSdkVersion` | 36 | |
| **16 KB page size** | **Required** | All native libraries must support 16 KB page alignment. Hard requirement for updates to apps targeting Android 15+ from **1 February 2027**. Verify with `bundletool`/`check_elf_alignment.sh` in CI. |

The 16 KB requirement is a build-time gate in CI, not a pre-release check. A native dependency added in month three that breaks alignment should fail the PR, not surface as a blocked release in 2027.

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
| Supabase service role | GitHub Environments, Vercel (server), EAS | 6 months |
| Gateway API + webhook keys | Supabase secrets | Per provider policy |
| SMS/WhatsApp provider | Supabase secrets | 12 months |
| Ed25519 QR signing key | **Supabase Vault** | 12 months, dual-key window |
| OTP pepper | **Supabase Vault** | 12 months |
| Play service account | EAS secrets | 12 months |
| Sentry DSN | Public — not a secret | — |
| Android upload key | EAS credentials + offline backup | Never |

Rotation is scheduled work with a runbook, not an incident response. The QR key rotation specifically supports two active keys simultaneously, because a carrier may be holding a token issued before rotation and be out of coverage until after it.

---

## 12. Observability

| Signal | Tool | Alert |
|---|---|---|
| Crashes / ANR | Sentry + Play Vitals | Crash-free < 99 %; ANR > 0.4 % |
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
| OTA fix | As needed | EAS Update → `production` channel |
| Feature release | Every 2 weeks | Full pipeline, staged rollout |
| Native release | Monthly, or when native changes require | Play, staged |
| Security hotfix | Immediate | Expedited, `min_supported_version` bump if warranted |
| Expo SDK upgrade | Quarterly, ~1 major behind latest | Dedicated branch, full regression |

Staying one Expo SDK behind the latest is deliberate. The newest release absorbs breaking changes from React Native and Android; a small team on a product where a failed release strands parcels benefits more from stability than from being current.

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
