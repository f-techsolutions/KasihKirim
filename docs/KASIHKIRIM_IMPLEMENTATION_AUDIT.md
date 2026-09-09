# KasihKirim Android — Implementation Audit

**Date:** 2026-09-09
**Audited state:** `feat/screenshot-demo` @ `d8c076e` (= `main` @ `553ffd9` + 7 commits; see §0)
**Method:** direct source inspection of every screen/ViewModel/repository under
`KasihKirimAndroid/app/src/main/java`; live inspection of the actual Supabase Cloud
project (`oyaesfvgqsdqmxmosqsr`) — schema, RLS, grants, RPC bodies — via the Supabase
MCP tools, not assumption; six dispatched GitHub Actions builds on this exact HEAD
lineage, all `assembleDebug` + `test` green; and, for Auth/Addresses/Kirim quote/Profile
role display specifically, live interactive testing by the product owner on a physical
Android phone this session, which surfaced and led to fixes for four real bugs (§0.3).
No emulator/device was available to this session directly, so screens not listed in
§0.3 are **code-verified, not device-verified** — flagged per-row below.

---

## 0. Repository state (read first — corrects the task brief)

### 0.1 Branch discrepancy

The task brief names `feat/android-phase1-foundation` as the "primary development
branch" and "authoritative." That branch's HEAD (`0e26f00`, 2026-09-07) **predates and
diverges from `main`**:

```
commits in main NOT in feat/android-phase1-foundation:  29
commits in feat/android-phase1-foundation NOT in main:   0   (fully superseded)
```

`main` (HEAD `553ffd9`, 2026-09-09 11:12) contains 29 additional merged commits beyond
phase1-foundation, including RLS `auth.uid()` policy fixes, pgTAP CI fixes, and the
delivery-proof-storage gate (PR #31). Auditing phase1-foundation would audit
already-superseded code and miss real, merged fixes.

`feat/screenshot-demo` (this session's branch, PR #32 open against `main`) —

```
git merge-base --is-ancestor origin/main origin/feat/screenshot-demo   → true
commits in feat/screenshot-demo NOT in main: 7
commits in main NOT in feat/screenshot-demo: 0
```

— is `main` plus exactly the work the task brief's own §8 ("UI/UX Requirements")
describes as already-existing baseline: the app icon, in-app branding, bottom-nav
icons, colored hero cards, status badges. That work only exists on this branch/PR;
`main` does not have it yet. **This audit is against `feat/screenshot-demo`**, since
auditing `main` alone would falsely mark §8's own stated baseline as missing, and
auditing phase1-foundation would falsely mark 29 merged commits' worth of fixes as
unapplied.

**Recommendation:** merge PR #32 into `main` (it is green, see §0.2) so `main` and the
task brief's stated baseline agree, and retire the phase-N branches — all are either
fully merged (superseded, safe to delete) or stale.

### 0.2 CI SDK issue — already fixed, not reproducible on this branch

Task brief §6/§19 asks to diagnose and fix `Failed to find package 'platforms;android-37'`.
That failure does not reproduce on `main`/`feat/screenshot-demo`. `.github/workflows/android-cloud-build.yml`
already contains the fix, landed in commits already on `main`:

- `d882d4a` — upgrade cmdline-tools before installing SDK packages
- `8494c4b` — clear stale `cmdline-tools/latest` before reinstalling
- `17b7409` — resolve pre-release SDK platform / AGP 9 Kotlin conflict

The workflow installs a current `cmdline-tools` release (the bundled 16.0 one can't
parse the newer SDK-XML schema `platforms;android-37` is published under) and pins
`sdkmanager --channel=3` (cumulative stable+beta+dev+canary) to resolve the pre-release
android-37 platform. **Evidence, not claim:** six builds dispatched this session on this
branch's commit lineage all completed `assembleDebug` successfully:

| Run | Commit | Conclusion |
|---|---|---|
| 34332090182 | 6c3b96b | success |
| 34340315112 / 34340315665 | c616c0a | success |
| 34341064567 | d3448cc | success |
| 34344789620 | 3f76f0b | success |
| 34349349467 | d8c076e (current HEAD) | success |

No change to the workflow file was needed or made. compileSdk/AGP were **not**
downgraded — AGP 9.4.0, Kotlin 2.3.21, compileSdk/targetSdk 37, minSdk 26, Gradle 9.6.0,
JDK 17 are all exactly as specified in the task brief §1, confirmed by reading
`gradle/libs.versions.toml` and `app/build.gradle.kts` directly.

### 0.3 What was actually device-tested this session (not just code-verified)

The product owner installed real debug APKs from the CI artifacts above on a physical
Android phone and exercised: sign-up/sign-in (found: unconfirmed-email error was
generic — unfixed product gap, see P2 below), Addresses create (found and fixed: silent
`canSubmit`-gate bug, twice — community selection and phone format), Kirim quote (found
and fixed: same silent-gate pattern on origin/destination + an undisclosed weight
range), and Profile role display for the carrier/seller demo accounts (found and fixed:
a real bug — see P0-1 below). These four fixes are the only claims in this document
backed by actual on-device interaction; everything else is source- and
schema-verified only.

### 0.4 Local build/test execution — could not run in this environment

```
$ gradle :app:test --no-daemon
FAILURE: Build failed with an exception.
* Where: Build file '.../KasihKirimAndroid/build.gradle.kts' line: 4
* What went wrong:
Plugin [id: 'com.android.application', version: '9.4.0', apply: false] was not found
  ... could not resolve plugin artifact 'com.android.application:...:9.4.0'
  Searched: Google, MavenRepo, Gradle Central Plugin Repository
```

This sandboxed session's egress proxy blocks `dl.google.com`/`maven.google.com`, so the
Android Gradle Plugin itself cannot be resolved locally — this fails before reaching
any module, so **no local Gradle task of any kind (not even JVM-only tests) can execute
in this environment.** Per the task's own Step 8 instruction, I am not claiming a build
success I did not observe locally. The only real build/test execution behind this
audit's claims is the six GitHub Actions runs in §0.2, which is CI's own
`./gradlew test --no-daemon` step (runs *before* `assembleDebug` in the workflow) —
those did pass, on real infrastructure, at this HEAD.

---

## 1. Feature audit

Status legend: **A** fully functional against real backend · **B** partially
functional · **C** UI-only/mocked · **D** backend-ready, no UI · **E** missing ·
**F** blocked by dependency/compliance decision.

| # | Feature | Role | Screen(s) | Current implementation | Backend dependency | Status | Known problems | Recommended action | Priority |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Sign up / sign in | All | AuthScreen | `AuthRepositoryImpl` → `auth.signUpWith(Email)`/`signInWith(Email)`, real Supabase Auth. Session encrypted at rest via `EncryptedSessionManager` (AndroidKeyStore AES-256-GCM), not the SDK's default plaintext SharedPreferences. Device-tested. | Supabase Auth, `public.profiles` | **A** (device-verified) | Unconfirmed-email sign-in maps to the generic `err_unexpected` string, not a "check your email" message — real but minor UX gap. No signup→`profiles` row trigger exists server-side; a brand-new real signup will FK-fail on first write until a profile row exists (worked around manually for the one test account this session, not fixed in migrations). | Add a DB trigger creating `profiles` on `auth.users` insert; add a dedicated "confirm your email" error mapping. | **P1** |
| 2 | Session persistence / restore | All | App-wide | `restoreSession()` calls `auth.awaitInitialization()`; `autoLoadFromStorage`/`alwaysAutoRefresh` on. Encrypted storage confirmed by reading `EncryptedSessionManager.kt` directly. | Supabase Auth | **A** | None found. | — | — |
| 3 | Sign out | All | Profile | `auth.signOut()`, clears local state unconditionally even on network failure (so the user is never stuck "signed in" after tapping out). | Supabase Auth | **A** (device-verified) | None found. | — | — |
| 4 | Role/status resolution | All | Nav, Home, Profile | **Fixed this session (P0).** Role/`carrier_id`/`seller_id`/`account_status` come from `public.custom_access_token_hook`, which enriches **only the minted JWT's own claims** — it never writes to `auth.users.raw_app_meta_data`. The app was reading `auth.currentUserOrNull()?.appMetadata`, which mirrors that never-updated column, not the token, so the enrichment could never reach the client even with the hook correctly configured. Fixed via `SupabaseClientProvider.currentJwtAppMetadata()`, which decodes the current access token's own payload; three call sites switched to it (`AuthRepositoryImpl.toAuthUser`, `VehicleRepositoryImpl`/`TripRepositoryImpl.requireCarrierId`). Device-verified for display; **not yet device-verified for carrier vehicle/trip creation**, which read the identical (now-fixed) claim. | `custom_access_token_hook`, `user_roles`, `carriers`, `sellers` | **A** (display, device-verified) / **B** (carrier-gated writes, code-fixed, not yet device-verified) | Zero automated test coverage for `currentJwtAppMetadata()` or for the fixed `requireCarrierId()` call sites — this exact bug class (reading the wrong object) could regress silently. | Add a unit test that constructs a fake JWT with an `app_metadata` claim and asserts `currentJwtAppMetadata()` extracts it; add carrier-id-presence assertions to `VehicleViewModelTest`/`TripsViewModelTest`. Have the carrier demo account actually add a vehicle and create a trip on-device to close the loop. | **P0** (test gap) |
| 5 | Kirim — Beli & Hantar quote | Customer | SendScreen | `KirimRepositoryImpl.quoteKirim` → `rpc_quote_kirim` with `p_kirim_type/p_category_slug/p_est_weight_grams/p_origin_node/p_dest_node/p_budget_cap_sen`. Response decoded field-by-field (`corridor_km`, `delivery_fee_sen`, `commission_sen`, `order_total_sen`, `carrier_earning_sen`, `pricing_rule_version`) — no client-side money math. Device-tested; two real silent-gate bugs found and fixed this session (origin/destination selection ambiguity, weight-range visibility). | `rpc_quote_kirim`, `internal.fn_quote_kirim`, `internal.pricing_rules` | **A** (device-verified) | None outstanding. | — | — |
| 6 | Kirim — submit / reference code | Customer | SendScreen | `createKirim` → `rpc_create_kirim` with `p_quote_id/p_item_description/p_dest_address_id/p_origin_address_id`. Reference code (`KK-YYMM-NNNNNN`) comes back from the RPC response (`internal.kirim_reference_seq` server-side) — **not generated client-side**, confirmed by reading `toKirimCreated()`, which only decodes `kirim_id`/`reference_code`/`expires_at` off the JSON the server returned. | `rpc_create_kirim`, `internal.kirim_reference_seq` | **A** (device-verified) | None outstanding. | — | — |
| 7 | Serviceability check | Customer, Carrier | ServiceabilityScreen | `AddressRepositoryImpl.checkServiceability` → `rpc_check_serviceability`. `toServiceability()` maps the response to four **distinct** sealed cases per the RPC's `reason` field: `Serviceable`, `OriginNotActive`, `DestinationNotActive`, `NoRoute`, plus `GeographyUnknown` fallback — not collapsed into one generic failure, matching brief §"SERVICEABILITY" exactly. `internal.fn_check_serviceability` (server) already separates identity→activation→routability as three ordered checks (0011_geography_identity.sql, applied this session). Picker upgraded this session to the same locked-selection component as Addresses/Kirim (was a silent-gate risk). | `rpc_check_serviceability`, `internal.fn_check_serviceability`, `ref.route_nodes`, `ref.districts` | **A** (code-verified; not yet device-tested since the picker fix) | Not yet device-tested post-fix. | Have the user run one origin/destination check on-device. | **P2** |
| 8 | Sabah-wide geography | All | Serviceability, Addresses, Kirim | Server-side: **Sabah-wide**, confirmed live via `execute_sql` this session — `ref.districts` has all 27 Sabah districts across 5 divisions seeded (status `PILOT` for Kota Kinabalu/Beluran, `PLANNED` for the rest), `service_areas` seeded per district (28 rows), Paitan seeded as a sub-district of Beluran with its own route nodes/edges **including a BOAT/river edge**. Client: `Community`/address search reads from `public.communities` and is not hardcoded to any corridor — any active community is searchable. | `ref.districts`, `ref.divisions`, `service_areas`, `route_nodes/edges` | **A** (schema-verified) — client correctly generic, but only 6 `communities` rows exist today (all in the pilot corridor), so only pilot-area addresses are actually selectable in the UI right now | Geography *support* is Sabah-wide; geography *data* is pilot-only. This is a data/rollout gap, not a code gap — do not read it as "not Sabah-wide" in code. | Seed `communities` rows for planned districts as they activate; no app code change needed. | **P2** (data, not code) |
| 9 | Board — browse & accept | Carrier | BoardScreen | `KirimRepositoryImpl.listBoard()` reads `kirim_requests` filtered `status=POSTED, visibility=board`, RLS-protected, not an open table scan. `acceptOffer` → `rpc_accept_offer` (`TripRepositoryImpl`), with `p_idempotency_key` — a real client-generated UUID passed to an idempotent server function, not a client-side "accepted" assumption. Success reloads the board from the server rather than locally mutating state, so a race with another carrier is reflected correctly. | `rpc_accept_offer`, `kirim_requests` RLS | **B** — code-verified, correct against schema; **not yet device-tested** by either demo account (carrier role display was broken until this session's last fix, so this flow was never reachable end-to-end on-device before now) | Never exercised on a real device end-to-end. | Have the carrier demo account post one Kirim (customer account) and accept it (carrier account) on-device. | **P1** |
| 10 | Trips — create / list | Carrier | TripsScreen | `createTrip` → `rpc_create_trip` (`p_vehicle_id/p_origin_node/p_dest_node/p_depart_at`); capacity is **derived server-side from the vehicle row**, confirmed by reading `internal.fn_create_trip`'s migration (0012) directly — the client never sends a capacity number. `listMyTrips` filters `carrier_id = requireCarrierId()` (now correctly sourced from the JWT, see #4). | `rpc_create_trip`, `carriers`, `vehicles` | **B** — code-verified; blocked from device-testing until now by the #4 bug (a carrier account could never actually reach `carrier_id`-gated screens with a correct claim before this session's fix) | Not yet device-tested. | Have the carrier demo account create one trip on-device now that #4 is fixed. | **P1** |
| 11 | Vehicles — CRUD | Carrier | VehiclesScreen | Standard Postgrest CRUD on `vehicles`, `carrier_id` injected from `requireCarrierId()` (same #4 fix). Activate/deactivate is a plain `is_active` update. Client-side validation (weight/volume/parcel fields) exists in `VehiclesViewModel`; server-side authority via RLS + NOT NULL/CHECK constraints on `public.vehicles` (confirmed in 0001_schema.sql). | `vehicles` RLS | **B** — same reasoning as #10 | Not yet device-tested. | Have the carrier demo account register one vehicle on-device. | **P1** |
| 12 | Orders (own Kirim list) | Customer | OrdersScreen | `listMyKirims()` filters `requester_id = currentUserOrNull()?.id` server-side via RLS-backed query — cannot see another user's orders (confirmed by reading the filter, and independently by the `kirim_requests` RLS policy read live this session). Status shown via `KirimStatus.labelMs`, sourced only from the 20-value enum below (#14) — no invented statuses. | `kirim_requests` RLS | **A** (device-adjacent — same data path as the device-tested Kirim submit flow) | None found. | — | — |
| 13 | Deliveries — lifecycle | Customer, Carrier | DeliveriesScreen | `listMyDeliveries()` reads `deliveries` (RLS-scoped) with an embedded `kirim_requests` join. `transition()` → `rpc_delivery_transition` with a client-generated idempotency key — **all transitions server-authorized**; the client only offers the buttons `NON_PROOF_DELIVERY_TRANSITIONS` (a static table matching `ref.delivery_transition_rules`' `requires_proof=false` rows) computes as currently legal for the delivery's status+role, but the server is the actual authority (`internal.fn_delivery_transition` validates against `ref.delivery_transition_rules` and rejects anything not in it). Proof-required transitions intentionally have no button yet (see #13a). | `rpc_delivery_transition`, `ref.delivery_transition_rules`, `internal.fn_delivery_transition` | **B** | Proof-of-delivery submission (`rpc_submit_proof`, storage bucket `pod`, both already applied server-side per 0014) has **no client UI at all** — any transition whose rule row has `requires_proof=true` is simply unreachable from the app today. Never device-tested. | Build the proof-submission UI (photo capture/upload to the `pod` bucket + `rpc_submit_proof` call) as its own phase; until then this is honestly a partial feature, not a complete one. | **P1** |
| 14 | Order/delivery status set | All | Orders, Deliveries | `KirimStatus` enum has exactly the 20 values in the task brief, verified by reading `KirimStatus.kt` line-by-line: DRAFT, POSTED, MATCHED, PROCURING, AWAITING_PICKUP, PICKED_UP, IN_TRANSIT, AT_HUB, OUT_FOR_DELIVERY, DELIVERED, COMPLETED, FAILED_PICKUP, FAILED_DELIVERY, PROCUREMENT_FAILED, RETURNING, RETURNED, CANCELLED, EXPIRED, DISPUTED, REFUNDED. **No `ACCEPTED` value exists anywhere in the codebase** (confirmed via grep). | `ref.kirim_status` enum | **A** | None. | — | — |
| 15 | Earnings | Carrier | EarningsScreen | `myEarnings()` → `rpc_my_earnings` (no params), decodes `available_sen/pending_sen/cod_held_sen/float_limit_sen`. Read-only display; no client-side balance mutation anywhere in the module (confirmed by grep across the whole `data/repository` package — no `.update()`/`.insert()` touches `internal.ledger_*`, `carriers.cod_held_sen`, or any balance column). | `rpc_my_earnings`, `internal.ledger_*` | **B** — code-verified, blocked from device-testing by #4 until now (Duit tab is carrier-only) | Not yet device-tested. | Have the carrier demo account open Duit on-device. | **P1** |
| 16 | Addresses — CRUD | Customer | AddressesScreen | Standard Postgrest CRUD on `addresses`, `user_id` injected from the session, RLS-scoped (`addresses_own` policy, read live this session). `setDefaultAddress` does a clear-then-set two-step to respect the `ux_addresses_one_default` unique constraint. Device-tested; the silent-gate community-selection bug found and fixed here first, then the same fix pattern carried to Kirim/Trips/Serviceability. | `addresses` RLS, `ux_addresses_one_default` | **A** (device-verified) | None outstanding. | — | — |
| 17 | Muatan Jual — browse | Seller (visible to all in current nav) | MuatanJualScreen | Reads `v_lot_listings`, a security-barrier view already filtered to `status='ACTIVE'` and unexpired server-side (confirmed by reading the repository's own comment plus the view definition in 0006). Purchasing is **not implemented anywhere in the app** — no buy button, no `rpc_buy_from_lot` call exists in `MuatanJualRepositoryImpl` or `MuatanJualViewModel`. The screen shows an explicit notice card, not a disabled-looking button, honestly communicating the gate per brief §"MUATAN JUAL". | `v_lot_listings` | **C** (browse-only by design, matches brief exactly) / purchasing is **F** (blocked — brief explicitly says do not activate) | None — this is working as specified. | Leave as-is pending the brief's own BUILD→TEST→LEGAL→ACTIVATE gate; do not add a buy flow without that sign-off. | — |
| 18 | Profile | All | ProfileScreen | Shows email, role badge, account-status badge (both sourced from the now-fixed JWT claim, #4), links to Addresses/Serviceability, sign out. Device-tested for role display specifically. | Same as #4 | **A** (device-verified) | None outstanding. | — | — |
| 19 | Jualan (Sales) | Seller | PlaceholderScreen | Literally `PlaceholderScreen(Destination.SALES)` — fetches nothing, renders a "coming soon" card. Confirmed by reading the composable: no repository, no ViewModel, no backend call exists for this tab at all. | none | **E** | Correctly labeled as not-built; not falsely presented as working. | Scope Phase 9 when reached. | — |
| 20 | Bottom navigation / role-based tabs | All | AppNavHost, Destinations | `tabsFor(role: UserRole)` is a pure function keyed off `AuthUser.primaryRole`, itself derived only from the (now-correctly-sourced) JWT roles claim — confirmed no other input feeds it. Explicitly documented in the code's own comment as "a CONVENIENCE, not a control" — hiding a tab does not hide the underlying screen from a determined client; RLS is the real boundary (matches brief §12 exactly). | JWT roles claim | **A** | None. | — | — |

---

## 2. Backend-ready features with no UI (task brief §4)

All twelve items were checked directly against the live schema this session
(`mcp__Supabase__execute_sql`/`list_tables` against project `oyaesfvgqsdqmxmosqsr`), not
assumed present because a migration file mentions them.

| Feature | Tables/RPCs confirmed live | Android UI | Status |
|---|---|---|---|
| Ajak Kirim (capacity invites) | `capacity_invites`, `invite_responses`, `restock_requests`, `rpc_send_capacity_invite` | none | **D** |
| Kongsi & Untung (referrals) | `promotions`, `promotion_attributions` | none | **D** |
| Reviews/ratings | `reviews` | none | **D** |
| Disputes | `disputes` | none | **D** |
| In-app messaging | `conversations`, `conversation_participants`, `messages` | none | **D** |
| Notifications | `notifications`, `internal.notification_outbox` | none | **D** |
| Badges | `user_badges`, `ref.badge_definitions` | none | **D** |
| Voucher campaigns | `voucher_campaigns`, `voucher_issuances` (1 campaign seeded live) | none | **D** |
| Commission | `internal.commission_rules` | Earnings screen shows the *result* only | **D** (no admin/config UI, correct — not an Android concern per brief §16) |
| Ledger | `internal.ledger_accounts/ledger_transactions/ledger_entries` | none (correctly — Android must never touch this directly, brief §15) | **D** |
| Payout | `internal.payouts`, `internal.bank_accounts` | none | **D** |
| COD | `internal.cod_collections`, `carriers.cod_held_sen` (shown read-only in Earnings) | read-only display only | **D** |
| Escrow | modeled inside `internal.ledger_*` (no dedicated escrow table — confirmed no `escrow` table exists in `list_tables` output) | none | **D** |

None of these were touched or scaffolded this session, per the brief's own instruction
not to activate anything gated. Money/ledger/payout/COD/escrow tables have **zero**
Android-side write path anywhere in the module — confirmed by grepping the whole
`data/repository` package for `.insert(`/`.update(`/`.upsert(` against any table name
containing `ledger`, `payout`, `cod`, `commission`, or `bank_account`: zero matches.

---

## 3. Security invariants (task brief §5) — verified, not assumed

| Invariant | Verification performed | Result |
|---|---|---|
| No service-role/`sb_secret_`/DB-password/connection-string in Android source | `grep -rniE` across `app/src` and `local.properties*` for `service_role`, `sb_secret`, `SUPABASE_SERVICE`, `postgres(ql)://`, `SUPABASE_DB_PASSWORD` | Two matches, both **comments** warning against doing it (`SupabaseClientProvider.kt`, `local.properties.example`) — no actual key material | **Pass** |
| Only the publishable key is wired | Read `app/build.gradle.kts`: only `SUPABASE_URL`/`SUPABASE_PUBLISHABLE_KEY` become `BuildConfig` fields | **Pass** |
| CI gate: no forbidden secret in source | `.github/workflows/android-cloud-build.yml` "GATE — no forbidden secret in Android sources" step, regex-matches key *material* (`sb_secret_...`, JWT-shaped strings, `SERVICE_ROLE=...`, `postgres(ql)://...`), not the bare word — already present, already passing on every run in §0.2 | **Pass** (pre-existing, confirmed still active) |
| CI gate: no secret survived into the built APK | `strings $APK \| grep -E 'service_role\|sb_secret_\|postgres(ql)://'` step, post-`assembleDebug` — already present | **Pass** (pre-existing, confirmed still active) |
| Client never mutates balances/ledger/commission/payout/COD/escrow | Grepped `data/repository/*.kt` for `.insert(`/`.update(`/`.upsert(` against any ledger/payout/cod/commission/bank_account table | Zero matches — every money-relevant call is `rpc_*` (`quoteKirim`, `createKirim`, `myEarnings`) | **Pass** |
| Client-side role is never trusted as authority | Confirmed by reading `Destinations.kt`'s own comment plus every RPC's server-side role check (`authz.my_carrier_id()`, `has_role()`) called live this session while applying migrations | **Pass** |
| Client-side pricing/commission never authoritative | `KirimQuote`/`KirimCreated` are decoded verbatim from `rpc_quote_kirim`/`rpc_create_kirim` responses; no arithmetic on money fields anywhere in `KirimRepositoryImpl` besides passing `Sen(...)` wrapper construction | **Pass** |
| Client-side delivery-status transitions never authoritative | `rpc_delivery_transition` is server-validated against `ref.delivery_transition_rules`; client only *offers* buttons for what it computes as legal, never writes a status directly | **Pass** |
| Client-side capacity reservation never authoritative | `rpc_create_trip` derives capacity server-side from the vehicle row (0012); `rpc_accept_offer` does the actual reservation server-side (`internal.fn_reserve_capacity`, confirmed via the function body read this session) | **Pass** |
| Service-role-only RPCs not exposed to normal users | `rpc_apply_payment_event`, `rpc_record_webhook`, `rpc_idem_*`, `rpc_consume_nonce`, `rpc_risk_signal`, `rpc_reconcile` — none referenced anywhere in `KasihKirimAndroid/` (confirmed via grep); their `GRANT EXECUTE` is service-role only per 0005_rpc_surface.sql | **Pass** |
| RLS enabled on all user-data tables | Live `list_tables` check this session: every table has `rls_enabled: true` **except** `spatial_ref_sys` (PostGIS system table, not user data) and the partitioned parent `delivery_events` (its monthly partitions each have RLS enabled individually — the parent itself does not, which is a Supabase advisory-flagged but low-severity finding, not a gap introduced this session) | **Pass**, with the one pre-existing advisory noted |

---

## 4. Test coverage

13 JVM unit test files exist, one per ViewModel with real logic (Auth, Addresses,
Board, Deliveries, Earnings, Muatan Jual, Orders, Kirim quote, Serviceability, Trips,
plus `MoneyTest`/`BackendEnumContractTest`/`SafeLogTest`). 3 instrumented tests
(`EncryptedSessionManagerTest`, `AuthScreenTest`, `ScreenshotDemoTest`). All ran green
in CI at this HEAD (§0.2's runs each execute `./gradlew test` before `assembleDebug`
and none failed).

**Gap found this session:** the JWT-decode fix (#4, P0) has **no test coverage** —
`SupabaseClientProvider.currentJwtAppMetadata()` and the two `requireCarrierId()` call
sites it feeds are untested. This is the same bug class that caused the original defect
(reading the wrong SDK object), so it is the single highest-value test to add next.

---

## 5. P0/P1/P2/P3 punch list

**P0 — correctness/regression risk, do next:**
- Add unit test coverage for `SupabaseClientProvider.currentJwtAppMetadata()` and the
  `requireCarrierId()` call sites (item #4). This is a client-code bug class with zero
  regression protection today.

**P1 — real gaps, device-test or build:**
- Device-test Board/Trips/Vehicles/Earnings end-to-end with the carrier demo account
  now that role resolution is actually fixed (#9, #10, #11, #15) — these were never
  reachable correctly before this session's last fix.
- Add a `public.profiles` auto-create trigger on signup (#1) — a real new signup will
  FK-fail today without one.
- Build proof-of-delivery submission UI (#13) — `rpc_submit_proof` and the `pod`
  storage bucket exist server-side with zero client entry point.

**P2 — minor/UX/data:**
- Map the unconfirmed-email sign-in failure to a specific message instead of the
  generic error string (#1).
- Device-test Serviceability post-picker-fix (#7).
- Seed `communities` rows as new districts move from `PLANNED` to active pilot status
  (#8) — a data task, not a code task.

**P3 — none identified this audit that aren't already covered above.**

---

## 6. Recommended next phase

Per the brief's own phase plan (§7), Phase 1 (auth/session/profile/nav) and the
Kirim/serviceability core of Phase 2 are **A-status and device-verified**. Phase 3
(Board/Trips/Vehicles) is **code-complete but device-unverified** because of the #4 bug
this session fixed — that is the concrete next step: put the carrier demo account
through Board→Trips→Vehicles on a real device before writing any new Phase 3 code, since
that is the cheapest way to convert nine "B" rows above to "A" or surface a second
JWT-claim-style bug if one exists. Phase 4 (delivery execution) is proof-of-delivery UI
away from being real, not a new phase. Phases 5-9 (financial UI, messaging, growth,
Muatan Jual activation) all correctly remain untouched per the brief's own gating.
