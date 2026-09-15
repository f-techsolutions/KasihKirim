# KasihKirim — P1-B Carrier End-to-End Validation

**Scope:** Validate the Carrier experience end-to-end — code audit, live-backend
rehearsal against the real Supabase Cloud project, and RLS/security probing.
**Not performed:** physical Android device testing (see "Device validation not
executable in this environment" below).

**Backend:** Supabase Cloud project `oyaesfvgqsdqmxmosqsr` (ap-south-1) — the
real, live production-shaped backend, not a local stub or mock.

**Account used:** the app's own real carrier demo account
(`965f8e50-3a99-4b97-9d63-d08cdaad5edd`, `carrier_id`
`01a085d5-1d33-7e00-ae92-925faacc9129`) — no password is recorded or needed
here; all backend calls were made by impersonating this account's JWT claims
directly against PostgREST's authorization path (see Methodology). Genuine
pre-existing data on this account (one real `CAR` vehicle, two real `POSTED`
kirim requests belonging to a different real user) was read but never
mutated, and is confirmed untouched at the end of this report.

---

## Device validation not executable in this environment

This session has no physical Android device or emulator display attached —
only a headless Linux container with source-code and Supabase MCP access. No
claim below should be read as "verified by tapping through the app on a
phone." Every finding is one of:

- **Static code audit** — reading the actual Kotlin/Compose source that ships
  in the APK (repositories, ViewModels, screens, navigation).
- **Live backend rehearsal** — calling the real Postgres RPCs and querying
  real RLS-protected tables through the same authorization path PostgREST
  uses for a genuine Android API call (see Methodology), using the app's own
  real carrier account and real data where possible.

### Manual test procedure for the user (run this on your own phone)

1. Sign in as the carrier demo account.
2. **Login/role/nav** — confirm the bottom nav shows exactly: Home, Trips,
   Orders, Earnings, Profile (no Board tab icon confusion, no seller-only
   "Jual" tab).
3. **Vehicles** — open Vehicles, confirm your one real vehicle. Edit its
   "Kapasiti Isipadu (cm³)" field to a realistic number for a car trunk (e.g.
   `300000`, not `10` — see Finding 1 below) and save. Confirm it persists
   after leaving and returning to the screen.
4. **Trips** — create a trip on a route you actually serve, with a real
   future depart time. Confirm capacity fields shown match the vehicle you
   picked, and that you cannot create a trip with a past depart time or with
   an inactive vehicle.
5. **Board** — from a second device/account (or ask a friend with the app),
   post a HANTAR or BELI request on the same corridor. Confirm it appears on
   your Board, that you cannot see the requester's address before accepting,
   and that accepting it succeeds once and fails with a clear error on a
   second attempt (or from a different carrier).
6. **Orders/Deliveries** — after accepting, open Orders → the accepted item
   → "onOpenDeliveries" link into your Deliveries list. Confirm the status
   badge always matches what you'd see in the requester's own Orders screen
   (never invents an "Accepted" status not in that list).
7. **Delivery transitions** — attempt to move the delivery from
   `AWAITING_PICKUP` to `PICKED_UP` from this screen. **Expected: you
   cannot** — see Finding 2 (POD gap) below; this is a known, pre-existing
   gap, not something introduced by this task.
8. **Earnings** — confirm the numbers shown match `carrier_earning_sen` from
   the accepted delivery(ies), not a locally-computed estimate.
9. **Profile** — confirm your email, a "Carrier" role badge, and account
   status are shown.
10. **Sign out** — confirm it returns you to the sign-in screen and a
    relaunch does not silently resume a stale session.

---

## Methodology: live rehearsal against the real database

Rather than mocking Postgres, every RPC/RLS claim below was exercised by
impersonating the exact JWT shape PostgREST hands to `auth.uid()`/
`authz.my_carrier_id()`/`authz.user_roles()` for a real API call, in a single
transaction so `set_config(..., true)` (session-local) actually takes effect
for the RPC call that follows it:

```sql
SELECT set_config('role','authenticated', true);
SELECT set_config('request.jwt.claims', jsonb_build_object(
  'sub', <uid>, 'role','authenticated',
  'app_metadata', jsonb_build_object('roles', jsonb_build_array('carrier'),
                                      'carrier_id', <carrier_id>)
)::text, true);
SELECT public.rpc_accept_offer(<trip>, <kirim>);  -- same query/transaction
```

This is not a stand-in for `authz.my_carrier_id()` — it's the literal
`current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata'` read
that function performs, confirmed by reading its live definition first.

---

## 1. Code audit — mocks, hardcoding, placeholders

Searched every carrier-facing screen/ViewModel/repository
(`ui/trips`, `ui/vehicles`, `ui/board`, `ui/earnings`, `ui/orders`,
`ui/deliveries`, `ui/profile`, `TripRepositoryImpl`, `VehicleRepositoryImpl`,
`EarningsRepositoryImpl`) for `TODO|FIXME|mock|dummy|hardcod|placeholder|fake`
(case-insensitive). **Result: clean.** The only match was `.toDomain()`,
which case-insensitively contains the substring `toDo` — not a real marker.

## 2. Role resolution & navigation

`Destinations.kt::tabsFor(UserRole.CARRIER)` →
`[HOME, TRIPS, ORDERS, EARNINGS, PROFILE]` — correct, distinct from the
customer/seller tab sets. `ProfileScreen.IdentityCard` renders
`user.primaryRole.wire` (server-decoded JWT role, not a client guess) as a
status badge. Role decoding itself (`JwtClaims`/`buildAuthUser`,
`AuthRoleResolutionTest`) was already covered by the P0 task's regression
suite (28 tests, CI green) and is out of scope to re-touch here per this
task's brief.

`OrdersScreen` (`Destination.ORDERS`) is shared across roles — it lists
`kirimRepo.listMyKirims()`, i.e. requests the signed-in user personally
*posted* as a requester, plus a link (`onOpenDeliveries`) into
`DeliveriesScreen`, which is the carrier's actual matched-deliveries list.
A carrier with no requests of their own therefore sees an empty Orders list
plus the Deliveries entry point — this is a legitimate design (a carrier
account can also post requests), not a bug, but worth naming precisely since
"Carrier Orders" in the Test Matrix below is really two screens.

## 3. Vehicles — CRUD + RLS isolation

Live-tested against the real `vehicles_own` RLS policy
(`carrier_id = authz.my_carrier_id()`, both `USING` and `WITH CHECK`) by
impersonating a JWT with a random, non-existent `carrier_id` and probing the
real carrier's real vehicle row (`01a0862d-85d8-7d84-8373-57369f145474`):

| Probe | Result |
|---|---|
| `SELECT` the other carrier's vehicle | 0 rows visible |
| `UPDATE is_active` on the other carrier's vehicle | 0 rows updated |

Cross-carrier isolation holds. No mock — real policy, real row, real
impersonated JWT.

**Finding 1 (data, not code):** the real demo carrier's vehicle has
`capacity_volume_cm3 = 10`. The Add/Edit Vehicle form's label is correctly
`"Kapasiti Isipadu (cm³)"` (unambiguous unit, no conversion bug in
`VehiclesViewModel.onVolumeChange`/`toDraftOrNull` — it's a raw digit
filter, no scaling applied). This is real, implausible data (10 cm³ ≈ two
teaspoons) most likely entered during earlier demo/testing, not a code
defect. **Practical impact, confirmed live:** with this value, the real
vehicle can only ever be matched to a kirim whose `volume_cm3 ≤ 10`, which
essentially no real item will satisfy — the demo account is functionally
unable to accept real board offers until this is corrected in-app (step 3 of
the manual procedure above). Not fixed here per the Bug Fix Rule, since it
is not a code defect — recommend the user simply edit their real vehicle's
capacity in the app.

## 4. Trips — creation, capacity, ownership

Read `rpc_create_trip`'s full live definition (`SECURITY DEFINER`,
`SET search_path TO ''`). Confirmed it rejects, server-side:

- non-carrier caller → `STATE_ACTOR_NOT_PERMITTED`
- a vehicle that is foreign, nonexistent, **or inactive** →
  `VEHICLE_NOT_FOUND`
- identical origin/destination → `INVALID_CORRIDOR`
- a depart time in the past → `DEPART_TIME_IN_PAST`

`capacity_weight_grams`/`capacity_volume_cm3`/`capacity_parcels` are always
derived from the chosen vehicle row server-side — never accepted from the
client. Verified live: called `rpc_create_trip` for real as the carrier
using their real vehicle on a Beluran→Kota Kinabalu corridor; it returned
`ANNOUNCED` with capacity fields matching the vehicle exactly.

`trips_update` RLS: `carrier_id = authz.my_carrier_id() AND status <>
'DEPARTED'`, both `USING`/`WITH CHECK` — mutation is ownership-scoped
regardless of the broader `trips_select` policy (any authenticated user, not
just the owner, may `SELECT` `ANNOUNCED`/`BOARDING` trips — a pre-existing,
intentional "public board" design, not something this task's scope covers
changing).

## 5. Board — accept/match eligibility

`rpc_accept_offer` had **zero pgTAP coverage anywhere in the suite**
(confirmed via grep — only `08_kirim_trip_creation.test.sql` touches
`rpc_create_kirim`/`rpc_create_trip`). This is a genuine, pre-existing gap in
automated regression coverage. To compensate, it was rehearsed live,
end-to-end, against the real trip created in §4:

1. Created a throwaway customer + address, quoted and posted a real BELI
   kirim (`rpc_quote_kirim` → `rpc_create_kirim`).
2. Impersonated the real carrier and called `rpc_accept_offer(trip, kirim)`.
   **First attempt raised `CAPACITY_EXCEEDED`** — a real, correct rejection
   caused directly by Finding 1's 10 cm³ vehicle capacity, not a bug in
   `rpc_accept_offer` (it demonstrates capacity enforcement is live and
   working). Re-quoted a second kirim with a 5 cm³ item to fit within the
   real vehicle's real (if unrealistic) capacity.
3. Second attempt **succeeded**: `{"status":"MATCHED","delivery_id":...,
   "reservation_id":...}`. Verified independently: `deliveries` row created
   with `status='MATCHED'`; `kirim_requests.status` flipped to `'MATCHED'`;
   `trips.reserved_{weight,volume,parcels}` incremented by exactly the
   accepted item's amounts.
4. **Negative case** — re-ran the identical `rpc_accept_offer` call against
   the now-`MATCHED` kirim: raised `STATE_INVALID_TRANSITION`, exactly as
   the source (`IF ... k.status <> 'POSTED' THEN RAISE EXCEPTION
   'STATE_INVALID_TRANSITION'`) specifies. This is the same code path that
   would reject an already-accepted, cancelled, or expired request — any
   non-`POSTED` status hits the identical guard.
5. Read (not separately re-executed live, since it's a single unconditional
   equality/inequality check with no live-state dependency): self-dealing is
   rejected via `k.requester_id = auth.uid()` → `SELF_DEALING`; a carrier's
   combined COD + procurement float exceeding `float_limit_sen` is rejected
   via `FLOAT_LIMIT_EXCEEDED` before any state mutation happens.
6. Over-capacity rejection at the `internal.fn_reserve_capacity` layer was
   also independently proven live in step 2 above, and is additionally
   covered by a pre-existing passing pgTAP assertion
   (`01_constraints.test.sql`: "fn_reserve_capacity refuses one unit beyond
   capacity").

All throwaway rows from this rehearsal (customer, address, quotes, kirim
requests, trip, delivery, reservation, delivery event) were deleted
afterward; the real carrier's `procurement_advance_sen`, which
`rpc_accept_offer` legitimately incremented by the accepted kirim's budget
cap (3500 sen) as part of its normal side effects, was reverted back to its
pre-rehearsal value of 0. Full verification of a clean rollback is in
§"Cleanup verification" below.

## 6. Orders — authoritative status

`OrdersViewModel`/`DeliveriesViewModel` never construct or infer a status:
`DeliveriesViewModel.transition()` calls `repo.transition(...)` then calls
`load()` again, re-fetching from the backend — the badge shown is always
whatever the server returned on the next fetch, never a locally-flipped
value. `KirimStatus.kt` mirrors `ref.kirim_status` exactly (its own doc
comment: *"there is no ACCEPTED state... Android NEVER decides a
transition"*) — grepped the whole app for the literal string `ACCEPTED`;
the only match is that same enum-definition file's comment explaining why it
does *not* exist as a value. No invented status anywhere in client code.

## 7. Earnings — real data only

`EarningsRepositoryImpl` (audited earlier this engagement, re-confirmed
unchanged) only reads `rpc_my_earnings` and performs no client-side
computation or mutation of monetary figures. Money throughout the schema is
`BIGINT` sen — `rpc_quote_kirim`'s real live output during this rehearsal
(`delivery_fee_sen`, `commission_sen`, `carrier_earning_sen`, all integers)
reconfirms no floating-point money path exists anywhere in this flow.

## 8. Profile — carrier identity

`ProfileScreen.IdentityCard` shows: email, a role badge sourced from
`user.primaryRole.wire` (server JWT-decoded, not client-inferred — see §2),
and `accountStatus` when present. This exact role-badge rendering path was
already exercised via device testing in the earlier P0 phase of this
engagement.

## 9. Security checks

- **Cross-carrier isolation** — live-verified in §3 (0 rows visible/mutable
  across carrier boundary, real RLS policy, no mock).
- **Internal schema unreachable** — `internal.*`/`audit.*` tables carry no
  grant to `authenticated`; this exact boundary is already covered by
  `02_rls.test.sql` ("ledger unreachable", "payments unreachable",
  "payouts unreachable", "audit log unreachable", all `throws_ok` 42501,
  and passing in the last CI run).
- **Self-dealing / float-limit / status-guard** on `rpc_accept_offer` — read
  from the live function body and one branch (status guard) proven live in
  §5; not merely assumed from documentation.
- **No client-controlled privilege escalation at signup** — reconfirmed
  scope boundary from the P1-A task; unrelated to carrier flows and not
  re-touched here.
- **No SECURITY DEFINER search_path hijack surface** — every RPC read this
  session (`rpc_create_trip`, `rpc_create_kirim`, `rpc_accept_offer`,
  `rpc_quote_kirim`, `rpc_submit_proof`) pins `SET search_path TO ''` and
  fully schema-qualifies every identifier.

## 10. Test Matrix

| Feature | UI audited | Backend verified live | Real data used | Error states checked | Security checked | Grade |
|---|---|---|---|---|---|---|
| Carrier login | ✓ (code) | — (device-only step) | n/a | — | — | **C** — not device-tested, see manual procedure |
| Role resolution | ✓ | ✓ (JWT decode covered by P0's 28 tests) | ✓ real account | n/a | ✓ server-derived, not client-guessed | **A** |
| Carrier navigation | ✓ `tabsFor(CARRIER)` | n/a | n/a | n/a | n/a | **A** |
| Vehicles | ✓ | ✓ (RLS isolation, live) | ✓ real vehicle | ✓ (cross-carrier UPDATE/SELECT blocked) | ✓ | **B** — real vehicle has an implausible capacity value (Finding 1, data not code) |
| Trips | ✓ | ✓ (`rpc_create_trip` live, real vehicle/route) | ✓ | ✓ (inactive vehicle, past depart time, wrong owner — all read from source, status-guard path live-proven) | ✓ ownership-scoped mutation | **A** |
| Board / matching | ✓ | ✓ (`rpc_accept_offer` full live rehearsal incl. negative retest) | ✓ real trip, throwaway kirim | ✓ (capacity, already-matched) | ✓ self-dealing/float-limit read from source | **A-** — zero pre-existing pgTAP coverage for `rpc_accept_offer` is a real gap this task didn't add tests for (documented, not fixed, per scope) |
| Carrier Orders / Deliveries | ✓ | ✓ (status always re-fetched, never invented) | ✓ | n/a | n/a | **A** |
| Earnings | ✓ (repository re-audit) | ✓ (`rpc_my_earnings` only, sen integers confirmed live via quote output) | ✓ | n/a | n/a | **A** |
| Profile | ✓ | ✓ (role badge is server-derived) | ✓ real account | n/a | n/a | **A** |
| Sign out | ✓ (code path exists) | — (device-only step) | n/a | — | — | **C** — not device-tested, see manual procedure |

## 11. Bug Fix Rule

No code defect was exposed by this rehearsal. Finding 1 (10 cm³ vehicle
capacity) is real data on a real row, not a code bug — the form's unit
label is correct and the value is user-editable; no fix applied, per the
Bug Fix Rule's "smallest fix" principle not applying to non-code findings.
No architecture, migration, or JWT-decoding changes were made.

## 12. Proof-of-delivery backend readiness (inspection only — not implemented)

- `rpc_submit_proof` (read live, full definition): validates the caller is
  the delivery's assigned carrier (`NOT_ASSIGNED_CARRIER` otherwise),
  requires a photo path for `PHOTO` method, computes a quality score
  (`STRONG` for QR/OTP/admin override, `SUSPECT` for photo+mock-location,
  `WEAK` otherwise), and upserts into `public.proofs`. Fully implemented and
  ready to be called.
- Storage layer ready: `storage.buckets` has a `pod` bucket with RLS
  policies `pod_insert_assigned_carrier` and `pod_select_counterparties`,
  both confirmed live.
- `ref.delivery_transition_rules WHERE requires_proof=true` — exactly 3
  rows: `AWAITING_PICKUP→PICKED_UP` (event `CONFIRM_PICKUP`, proof leg
  `pickup`), `OUT_FOR_DELIVERY→DELIVERED` (event `CONFIRM_DELIVERY`, proof
  leg `dropoff`), `RETURNING→RETURNED` (event `CONFIRM_RETURN`, proof leg
  `dropoff`).
- `DeliveriesScreen`'s `NON_PROOF_DELIVERY_TRANSITIONS` filters out every
  `requires_proof=true` rule (confirmed by reading the import and its use as
  `availableEvents` in `DeliveriesScreen.kt`). **Concrete consequence: a
  carrier using the current Android app can never move a delivery past
  `AWAITING_PICKUP`, `OUT_FOR_DELIVERY`, or into `RETURNED` — those three
  transitions have no button anywhere in the UI today**, even though the
  backend, storage bucket, and RPC are all fully ready to accept proof
  submissions. This is a pre-existing, real gap — the backend is ready, the
  UI to drive it is not. No POD UI was built in this task, per the brief's
  explicit "inspect, do not implement."

## Cleanup verification

All throwaway rows created during this rehearsal were deleted and the one
mutated real row was reverted; final live counts:

| Row | Count after cleanup |
|---|---|
| Throwaway delivery | 0 |
| Throwaway trip_reservations | 0 |
| Throwaway trip | 0 |
| Throwaway kirim_requests (both) | 0 |
| Throwaway quotes (both) | 0 |
| Throwaway address | 0 |
| Throwaway customer profile | 0 |
| Throwaway customer auth.users | 0 |
| Real carrier `procurement_advance_sen` | `0` (pre-rehearsal value) |
| Real carrier `cod_held_sen` | `0` (untouched throughout) |
| Real vehicle `capacity_volume_cm3` | `10` (untouched — still the real, uncorrected value from Finding 1) |
| Real user's own `POSTED` kirim_requests | `2` (untouched) |

---

## Summary

- No mock/placeholder code found anywhere in the carrier-facing app.
- Role resolution, navigation, vehicle isolation, trip creation, board
  matching (including a full live accept/reject rehearsal with a real
  negative-case retest), order status authority, earnings, and profile
  identity all check out against the real live backend.
- One real data issue found (not a code bug): the demo carrier's vehicle has
  an implausibly small volume capacity (10 cm³), which live-testing proved
  blocks real board matches until corrected in the app.
- One real, pre-existing coverage gap documented: `rpc_accept_offer` has no
  pgTAP tests (not added here, out of this task's fix scope).
- One real, pre-existing UI gap documented: 3 of the 3 proof-required
  delivery transitions have no UI affordance today, despite the backend
  being fully ready — a de facto POD blocker for any real delivery.
- **Device validation not executable in this environment.** See the manual
  test procedure above for the user to run on their own phone.
