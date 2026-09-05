# KasihKirim — Development Environment

**Product scope: Sabah-wide.** Beluran, Paitan and Kota Kinabalu are the initial
pilot locations used for controlled operational testing. All 27 Sabah districts
are represented in the system from day one; activation is configuration.

Platform: **Android only.** No iOS toolchain is required or supported.

---

## 1. Why this document exists

The verification gate — `supabase db reset && supabase test db` — has **never
been executed**. The authoring environment had no Docker, no Postgres and no
Supabase CLI, and no network egress to install them. Everything in this
repository is written and statically reviewed, not verified.

This document exists so the first person with a real machine can run the gate
without guessing at prerequisites.

---

## 1a. Minimum cloud environment requirement

**Do not choose an environment because it offers a terminal.** The single
disqualifying test is whether `docker info` returns successfully. If it does
not, `supabase start` cannot run and nothing in this repository can be verified.

### Mandatory capabilities

| Capability | Why | Verify with |
|---|---|---|
| **Docker daemon, reachable** | Supabase local stack is containerised | `docker info` |
| **Privileged / Docker-in-Docker** | The daemon must run *inside* the workspace | `docker run hello-world` |
| **Supabase CLI** | Migrations, pgTAP, Edge Functions | `supabase --version` |
| **PostgreSQL client** | Seed, serviceability and RLS inspection | `psql --version` |
| **Node 20 LTS** | Repository specification — see §2a | `node --version` |
| **Deno** | Edge Function local execution | `deno --version` |
| **Outbound network** | Pulls Supabase images and packages | `npm ping` |
| ≥ 4 vCPU / 8 GB RAM / 32 GB disk | Supabase pulls ~6 containers | — |

### The requirement is platform-independent

**No platform is mandated.** Codespaces + Docker-in-Docker is one option, not
the decision. Any Linux environment qualifies if it satisfies the capability
table above.

| Option | Provisioning | Note |
|---|---|---|
| Dedicated Linux VM / VPS | `scripts/bootstrap-linux.sh` | Most control; needs sudo and egress |
| GitHub Codespaces | `.devcontainer/` | Convenient; needs 4-core+ for the stack |
| Gitpod | `.gitpod.yml` | Convenient |
| WSL2 (Ubuntu) | `scripts/bootstrap-linux.sh` | Works; Docker Desktop integration on |
| Local Linux workstation | `scripts/bootstrap-linux.sh` | Works |

Each provisions the same set: Docker Engine, Node 20 via nvm (`.nvmrc` is the
source of truth), Deno, PostgreSQL client, Java 17 and the Supabase CLI.

### Docker is the primary gate

```bash
docker info
docker run hello-world
```

If either fails, **stop**. Do not compensate by removing migrations, replacing
Supabase, mocking PostgreSQL, skipping tests, changing schema or weakening
assertions. Fix the environment.

### Known-unsuitable

Sandboxes without a Docker daemon, browser-only editors, and any environment
with blocked package-registry egress. The authoring environment for this
repository was unsuitable on all three counts, which is why nothing here has
been executed.

### Android in the cloud

**Emulator execution is not required and is not attempted.** The strategy is:

```
CLOUD BUILD  →  APK / AAB  →  REAL ANDROID DEVICE
```

Builds run through EAS; testing happens on physical low-end hardware, which is
the only way to observe the OEM battery-manager and thermal behaviour that
matters for this market. `profile=cloud` therefore treats Android tooling as
optional; `profile=full` requires it.

---

## 2. Prerequisites

| Tool | Version | Needed for |
|---|---|---|
| Docker Desktop / Engine | 24+ | Supabase local stack |
| Supabase CLI | 1.200+ | Migrations, tests, Edge Functions |
| Node.js | **20 LTS — pinned** | Mobile app, admin console. See §2a. |
| JDK | 17 | Android builds |
| Android SDK | API 36 | `targetSdkVersion 36` |
| EAS CLI | latest | Cloud builds, OTA |
| Deno | 1.45+ | Edge Function local run |

```bash
npm i -g supabase eas-cli
docker info && supabase --version && node --version
```

### 2a. Node version is pinned to 20 LTS

`.nvmrc`, `.node-version` and `apps/mobile/package.json#engines` all declare
Node 20. **Node 22 is not equivalent and must not be substituted** because the
environment happens to provide it. React Native and Expo native module
compatibility is validated against the LTS line.

```bash
nvm use          # or: fnm use
node --version   # expect v20.x
```

The doctor reports a mismatch as WARN, naming both versions. It does not
silently accept 22.

### 2b. The ordered gate

```bash
./scripts/verify-gate.sh
```

Runs the twelve gates in order and **stops at the first failure**. Gates 10-12
(`supabase start` / `db reset` / `test db`) are unreachable unless 1-9 pass, so
the database cannot be described as verified without the commands having run.

| # | Gate | # | Gate |
|---|---|---|---|
| 1 | Environment provisioned | 7 | `node --version` is 20 |
| 2 | Doctor passes | 8 | `deno --version` |
| 3 | `docker info` | 9 | `npm ping` |
| 4 | `docker run hello-world` | 10 | `supabase start` |
| 5 | `supabase --version` | 11 | `supabase db reset` |
| 6 | `psql --version` | 12 | `supabase test db` |

### 2c. Doctor

```bash
./scripts/kasihkirim-doctor.sh --profile=cloud   # backend gate only
./scripts/kasihkirim-doctor.sh --profile=full    # + Android build tooling
```

| Status | Meaning |
|---|---|
| PASS | Tool present and executed |
| FAIL | Required for this profile, missing or broken |
| WARN | Genuinely optional, or a version mismatch |
| BLOCKED | Absent and uninstallable here (no registry egress) |

Exit 0 only when the gate can actually be attempted. Secret **values** are
never printed — presence is reported as SET/UNSET.

---

## 3. First run

```bash
git clone <repo> && cd kasihkirim

supabase start          # boots Postgres, Auth, Storage, PostgREST
supabase status         # note API URL and anon key
```

### 3.1 The verification gate

```bash
supabase db reset       # applies 0000 → 0008 from empty, then seed.sql
supabase test db        # 84 pgTAP assertions
```

**Both must be green before any feature work.** Migration order is load-bearing:

| File | Why the order matters |
|---|---|
| `0000_prelude` | Extensions, schemas, `uuidv7`, **auth helpers**. Postgres resolves functions used in RLS policies at policy-creation time, so `auth.is_admin()` must exist before any later migration creates a policy calling it. |
| `0001_schema` | Tables in dependency order. Two FKs added by `ALTER` afterwards to break a cycle. |
| `0002` → `0008` | Supporting entities, functions/RLS, money, RPC surface, commerce, compliance, Sabah-wide geography. |

### 3.2 Expected first-run failures

These are anticipated, not defects to route around. **Do not weaken a test to
make it pass.**

| Symptom | Likely cause |
|---|---|
| `tests.create_user` fails on `auth.users` | GoTrue column set differs by version. Add the missing NOT NULL column to the helper. |
| `throws_ok` SQLSTATE mismatch | Trigger `RAISE` gives `P0001`; only real constraints give `23514`. Correct the expected code — never relax to `NULL` to hide it. |
| `pg_cron` extension missing | Guarded in `0000`; jobs are skipped locally. Expected. |
| `pgtap` not found | `CREATE EXTENSION pgtap` — included in `tests/00_helpers.sql`. |

---

## 4. Environment variables

```bash
cp apps/mobile/.env.example apps/mobile/.env
```

| Variable | Where | Notes |
|---|---|---|
| `EXPO_PUBLIC_SUPABASE_URL` | Mobile | From `supabase status` |
| `EXPO_PUBLIC_SUPABASE_ANON_KEY` | Mobile | Public by design; useless without a valid JWT |
| `SUPABASE_SERVICE_ROLE_KEY` | **Server only** | Edge Functions and admin console. **Never in the Android bundle.** CI greps for it. |
| `OTP_PEPPER` | Supabase secret | `openssl rand -hex 32` |
| `QR_PUBLIC_KEY` / `_PREVIOUS` | Supabase secret | Ed25519; two keys valid across a rotation window |
| `PAYMENT_WEBHOOK_SECRET` | Supabase secret | From provider — **not yet obtained** |

---

## 5. Edge Functions

```bash
supabase functions serve
supabase functions deploy quote-kirim delivery-transition handover-verify
supabase functions deploy payment-webhook --no-verify-jwt   # HMAC, not JWT
```

`payment-webhook` is the only function deployed without JWT verification: it
authenticates by HMAC over the raw request body.

---

## 6. Android app

```bash
cd apps/mobile && npm install && npx expo start
```

Currently 8 screens exist (splash, phone, OTP, customer home, Kirim wizard
step 1). The remaining flows exist in `prototype/kasihkirim.html`, which runs in
any browser with no install and serves as the UI specification.

```bash
eas build -p android --profile preview      # APK, internal
eas build -p android --profile production   # AAB, Play
```

---

## 7. Working with geography

Geography is **configuration, not code**. There is no `if district == 'Beluran'`
anywhere in the repository, and adding one is a review failure.

```sql
-- Open a district. No Android release required.
UPDATE ref.districts
   SET status = 'ACTIVE', status_reason = 'Ops approved 2026-Q4',
       status_changed_by = '<admin uuid>'
 WHERE code = 'SBH-SDK';

-- Ask the server whether a lane is served.
SELECT public.rpc_check_serviceability(
  (SELECT id FROM ref.route_nodes WHERE name='Kota Kinabalu'),
  (SELECT id FROM ref.route_nodes WHERE name='Sandakan'));
```

Hierarchy: `regions → divisions → districts → mukims → communities →
service_areas → pickup_points`, with `route_nodes`/`route_edges` as the
transport graph. Sub-districts such as Paitan hang off a parent district via
`parent_district_id`.

District status: `PLANNED`, `PILOT`, `ACTIVE`, `SUSPENDED`,
`TEMPORARILY_UNAVAILABLE`. Every change writes to `audit.audit_logs`.

---

## 8. Adding a transport type

Water routes are first-class. Adding a mode is two statements and no redesign:

```sql
ALTER TYPE ref.vehicle_type ADD VALUE 'FERRY';
INSERT INTO ref.transport_types (code, name_ms, name_en, medium, ...)
VALUES ('FERRY','Feri','Ferry','water', ...);
```

---

## 8a. Open static findings — DO NOT FIX WITHOUT A DECISION

Both were found by static review. Neither has been runtime-confirmed, and
neither is to be changed until the gate is green and the decision is made.

### SR-1 — `07_compliance.test.sql` references an unseeded Sandakan route node

**STATIC FINDING — REQUIRES DESIGN/SEED DECISION.**

Districts are seeded Sabah-wide (27). *Route nodes* are seeded only for the
Beluran/Paitan/KK pilot corridor (13 nodes). The serviceability assertion looks
up `route_nodes WHERE name='Sandakan'`, gets NULL, and will therefore receive
`GEOGRAPHY_UNKNOWN` where it asserts `DESTINATION_NOT_ACTIVE`.

Do **not** add arbitrary Sandakan route data. The right fix depends on the
intended route-graph model:

| Option | Consequence |
|---|---|
| **A** — a representative node per active/planned district | Serviceability answers Sabah-wide immediately; a large curated dataset must be maintained, and node quality drives pricing |
| **B** — tests use only explicitly seeded pilot routes | Smallest change; serviceability stays silent about unopened districts |
| **C** — administrative geography and operational route data kept separate | Cleanest separation: a district can be `PLANNED` with no graph at all, and the graph grows as operations do |

Unresolved. The distinction matters because `route_edges.distance_km` feeds the
pricing engine, so a fabricated node produces a fabricated price.

### SR-2 — `ref` schema is not reachable by the mobile client

**STATIC FINDING — REQUIRES ARCHITECTURE DECISION.**

`config.toml` exposes only `["public","graphql_public"]`. Migration `0008`
grants `SELECT ON ref.divisions, ref.transport_types TO authenticated`, which is
inert: PostgREST cannot address the schema for any role. The app cannot list
districts, divisions or transport types.

**Do not expose the whole `ref` schema.** The accepted direction is:

```
Mobile → controlled public view / RPC → approved reference data
```

not

```
Mobile → unrestricted ref schema
```

Same defect class as the earlier Edge Function `schema('internal')` bug: a grant
that looks correct but addresses an unreachable schema. Awaiting the decision.

---

## 9. What is blocked

| Item | Needs |
|---|---|
| **Verification gate** | Docker + Supabase CLI on a real machine |
| Prepaid payments | MJ-01 — escrow vs Bank Negara. **Legal.** |
| Muatan Jual activation | `compliance_status = PRODUCTION_ACTIVE`; see `MUATAN-JUAL-COMPLIANCE.md` |
| Push notifications | FCM project + service account |
| Signed AAB | Google Play developer account |
