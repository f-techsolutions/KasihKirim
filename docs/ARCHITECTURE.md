# KasihKirim — System Architecture

**Version 1.0** · Android-only mobile · Supabase backend · Next.js admin

**Product scope: Sabah-wide** (all 27 districts, configuration-driven activation). Beluran, Paitan and Kota Kinabalu are the **initial pilot locations**, not the product scope.

Companion documents: [`PRD.md`](./PRD.md) · [`DATABASE.md`](./DATABASE.md) · [`API.md`](./API.md) · [`SECURITY.md`](./SECURITY.md) · [`ANDROID.md`](./ANDROID.md) · [`TESTING.md`](./TESTING.md) · [`DEPLOYMENT.md`](./DEPLOYMENT.md)

---

## 1. Architectural principles

These are the rules that resolve disputes. When a design choice is unclear, the earlier principle wins.

1. **The server owns truth.** State, money and time are decided server-side. The client submits intents and renders results.
2. **Invariants live in the database.** Constraints and locks first, functions second, application code third, UI last. If an invariant can be expressed as a CHECK constraint, it must be.
3. **Default deny.** Every table has RLS. Every mutating endpoint requires an authenticated actor with an explicit grant. New tables are inaccessible until a policy is written for them.
4. **Money is a ledger, not a column.** Every value movement is a balanced double-entry transaction. Balances are derived.
5. **Offline is normal, not exceptional.** The network is assumed absent. Every write is queued, keyed and replay-safe by construction.
6. **Every byte is paid for by the user.** Payload size is a first-class design constraint, not an optimisation phase.
7. **Physical-world actions need physical-world proof.** Handovers require cryptographic or human proof, capturable without signal.
8. **Boring, verifiable, few dependencies.** Supabase-native primitives over bespoke infrastructure; each added dependency must justify its weight against a 2 GB phone.

---

## 2. System context

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              KasihKirim                                   │
│                                                                           │
│  ┌────────────────────┐              ┌─────────────────────────────┐     │
│  │  Android App       │              │  Admin Console              │     │
│  │  Expo / RN / TS    │              │  Next.js (App Router)       │     │
│  │  Expo Router       │              │  Server Components          │     │
│  │  SQLite + Outbox   │              │  service_role, server-only  │     │
│  │  Customer/Seller/  │              │  Ops / Finance / Support /  │     │
│  │  Carrier/Agent     │              │  Compliance                 │     │
│  └─────────┬──────────┘              └──────────────┬──────────────┘     │
│            │ HTTPS/JWT                              │ HTTPS/JWT+MFA      │
│            ▼                                        ▼                     │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │                        Supabase Platform                            │  │
│  │  ┌──────────┐ ┌──────────┐ ┌────────────┐ ┌──────────┐ ┌────────┐ │  │
│  │  │ Auth     │ │ PostgREST│ │ Edge Funcs │ │ Storage  │ │Realtime│ │  │
│  │  │ phone    │ │ RLS reads│ │ Deno       │ │ buckets  │ │ chat + │ │  │
│  │  │ OTP+JWT  │ │ + RPC    │ │ money/     │ │ +transform│ │ status │ │  │
│  │  │          │ │          │ │ webhooks   │ │          │ │        │ │  │
│  │  └──────────┘ └────┬─────┘ └─────┬──────┘ └──────────┘ └────────┘ │  │
│  │                    │             │                                  │  │
│  │              ┌─────▼─────────────▼──────────────────────────────┐  │  │
│  │              │  PostgreSQL 15+  (PostGIS, pg_cron, pgsodium)    │  │  │
│  │              │  public │ internal │ audit │ ref  schemas        │  │  │
│  │              │  RLS · state machines · double-entry ledger      │  │  │
│  │              └──────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└───────────────┬───────────────┬──────────────┬────────────┬─────────────┘
                │               │              │            │
        ┌───────▼──────┐ ┌──────▼─────┐ ┌──────▼─────┐ ┌───▼──────────┐
        │ Payment      │ │ SMS/       │ │ Expo Push  │ │ Sentry       │
        │ Gateway (MY) │ │ WhatsApp   │ │ → FCM v1   │ │ observability│
        │ FPX/DuitNow/ │ │ OTP        │ │            │ │              │
        │ e-wallet/card│ │            │ │            │ │              │
        └──────────────┘ └────────────┘ └────────────┘ └──────────────┘
```

### 2.1 Why no separate application server

A conventional Node/NestJS tier was considered and rejected for this product:

- Supabase already provides authenticated, RLS-enforced data access. Re-implementing it in a middle tier duplicates the authorisation surface and creates a second place for it to be wrong.
- The transactional invariants that matter here — capacity reservation, state transitions, ledger balance — are best expressed *inside* the transaction, in Postgres, not across a network hop.
- A separate always-on tier adds cost, deploy surface and failure modes for a product whose peak concurrency is modest.

Edge Functions cover the remaining need: anything that talks to the outside world, anything that must not be reachable by a client JWT, and anything that composes multiple operations.

**Cold starts** are the accepted trade-off. Mitigation: keep money-path functions small, avoid heavy imports, and route latency-sensitive reads through PostgREST instead.

---

## 3. Layered responsibility model

| Layer | Technology | Owns | Never does |
|---|---|---|---|
| **L1 Presentation** | Expo / RN / TypeScript | Rendering, input, local state, optimistic UI, offline queue | Compute prices, decide states, trust its own clock |
| **L2 Edge** | Deno Edge Functions | External I/O, webhooks, orchestration, signed-token issue/verify, matching, admin ops | Hold long-lived state |
| **L3 Data API** | PostgREST + RPC | Authorised reads; transactional writes via `SECURITY DEFINER` functions | Expose `internal` schema |
| **L4 Domain** | Postgres functions, triggers, constraints | State machines, capacity, ledger, commission, audit | Call outward (except via outbox) |
| **L5 Storage** | Supabase Storage | Images, KYC docs, POD, evidence; transforms | Serve KYC publicly |
| **L6 Scheduling** | `pg_cron` + Edge | Expiry, settlement, reconciliation, retries, digests | Duplicate work (advisory-locked) |

### 3.1 Where does a given operation belong?

| Operation shape | Goes to | Reason |
|---|---|---|
| Read own/permitted rows | PostgREST + RLS | Cheapest, no cold start |
| Read requiring cross-entity ranking | RPC (`SECURITY DEFINER`) | One round trip, server-controlled ordering |
| Write with a database invariant | RPC in a transaction | Lock and constraint in the same transaction |
| Write touching money | Edge Function → RPC | Idempotency + audit + external calls |
| External API call | Edge Function | Secrets never reach the client |
| Anything triggered by an external system | Edge Function (webhook) | Signature verification |
| Anything on a schedule | `pg_cron` → RPC or Edge | Single scheduler |

---

## 4. Mobile application architecture

### 4.1 Stack

| Concern | Choice | Rationale |
|---|---|---|
| Framework | Expo SDK 57+ (RN 0.86, React 19.2, New Architecture) | Managed native config via config plugins; EAS Build/Update/Submit; no `android/` churn |
| Routing | Expo Router (file-based) | Typed routes, deep links, lazy route loading |
| Language | TypeScript strict | `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes` |
| Server state | TanStack Query v5 + persisted cache | Retry/backoff, stale-while-revalidate, offline mutation queue integration |
| Local database | `expo-sqlite` (WAL) | Cache + outbox durability across kill/reboot |
| Client state | Zustand | Small, no boilerplate, no Redux weight |
| Forms | React Hook Form + Zod | Zod schemas shared with Edge Function validation |
| Lists | FlashList | Required for low-RAM virtualisation |
| Images | `expo-image` | Disk cache, `recyclingKey`, placeholder support |
| Secure storage | `expo-secure-store` | Android Keystore-backed token storage |
| Camera / QR | `expo-camera` | Single module for POD photo and QR scan |
| Push | `expo-notifications` → FCM v1 | Channels, categories |
| Location | `expo-location` + foreground service | No background-location permission — see `ANDROID.md` §4 |
| i18n | `i18next` + `expo-localization` | ms-MY default |
| Errors | `@sentry/react-native` | Crashes, ANR, breadcrumbs, release health |

**Rejected:** Redux Toolkit (weight), Reanimated-heavy motion systems (jank on the floor device), moment.js (bundle), `react-native-maps` for general browsing (memory; used only on the carrier trip screen), WatermelonDB (complexity beyond need), any iOS-only dependency.

### 4.2 Module layout

```
app/                            # Expo Router — routes only, thin
  (auth)/                       # phone, otp, onboarding
  (customer)/                   # home, board, marketplace, cart, orders, tracking
  (seller)/                     # products, inventory, orders, sales, payouts
  (carrier)/                    # trips, board, manifest, scan, earnings, payouts
  (agent)/                      # hub intake, release, assisted order, cash
  (shared)/                     # profile, addresses, chat, notifications, disputes
  _layout.tsx                   # providers, role gate, force-upgrade gate

src/
  features/                     # vertical slices — the primary unit of organisation
    kirim/        { api, hooks, components, screens, machine, schema }
    board/
    trip/
    marketplace/
    cart/
    payment/
    handover/                   # QR + OTP + POD
    tracking/
    chat/
    dispute/
    wallet/
  core/
    api/           client, error mapping, idempotency, retry policy
    db/            sqlite schema, migrations, repositories
    sync/          outbox, puller, conflict policy, scheduler
    auth/          session, role context, token refresh
    net/           connectivity observer, data-saver policy
    media/         compression, upload queue, cache budget
    notifications/ channels, handlers, inbox
    i18n/
    telemetry/
  ui/                           # design system primitives, tokens
  types/                        # generated Supabase types + domain types
```

**Rule:** features may depend on `core` and `ui`; features may not import each other. Cross-feature needs go through `core` or an explicit shared module. This keeps the dependency graph acyclic and the bundle splittable.

### 4.3 Role model in the client

A single account can be customer, seller, carrier and agent at once. Roles are read from the JWT `app_metadata.roles` claim, exposed via a `RoleContext`, and drive:

- which route groups mount (unmounted groups are not in the initial bundle),
- which navigation tabs render,
- an in-app role switcher that never requires logout.

Client-side role gating is **navigation convenience only**. Authorisation is RLS. A tampered client can reach a route but cannot read or write anything the JWT does not permit.

---

## 5. State machines

State machines are defined once, in data (`ref.*_transition_rules`), and enforced by a single generic transition function per domain. The client mirrors them read-only for UI affordances; it never decides a transition.

### 5.1 Delivery (core)

```
                    ┌─────────┐
                    │  DRAFT  │
                    └────┬────┘
                         │ submit
                    ┌────▼─────┐  no match by TTL   ┌──────────┐
              ┌─────┤  POSTED  ├───────────────────►│ EXPIRED  │
              │     └────┬─────┘                    └──────────┘
              │          │ offer accepted (either side)
    cancel    │     ┌────▼─────┐
    (free)    │     │ MATCHED  │ capacity reserved · handover codes issued
              │     └────┬─────┘
              │          │
              │          │  ┌───────────────────────────────────────────┐
              │          │  │  BELI branch (procurement)                │
              │          ├─►│  PROCURING ──► price_variance? ──┐        │
              │          │  │      │            (approve/reduce/decline)│
              │          │  │      │                           ▼        │
              │          │  │      │              PROCUREMENT_FAILED    │
              │          │  │      ▼                    (refund)        │
              │          │  └──── goods bought, receipt captured ───────┘
              │          │              │
              │          │ carrier en route to origin (HANTAR/PASARAN)
              │     ┌────▼──────────────┐
              │     │ AWAITING_PICKUP   │
              │     └────┬──────────┬───┘
              │  proof   │          │ pickup failed (×3 or window lapsed)
              │  ok      │          └──────────────► FAILED_PICKUP ──┐
              │     ┌────▼──────┐                                     │
              │     │ PICKED_UP │                                     │
              │     └────┬──────┘                                     │
              │          │ departs                                    │
              │     ┌────▼───────┐   hub transfer  ┌──────────┐       │
              │     │ IN_TRANSIT ├────────────────►│  AT_HUB  │       │
              │     └────┬───────┘◄────────────────┴────┬─────┘       │
              │          │ arrives destination node     │             │
              │     ┌────▼──────────────┐               │             │
              │     │ OUT_FOR_DELIVERY  │◄──────────────┘             │
              │     └────┬──────────┬───┘                             │
              │  proof   │          │ recipient absent / refused      │
              │  ok      │          └────► FAILED_DELIVERY ──┬────────┤
              │     ┌────▼──────┐            (retry ≤2)      │        │
              │     │ DELIVERED │◄───────── retry ───────────┘        │
              │     └────┬──────┘                                     │
              │          │ settlement window elapsed, no dispute      │
              │     ┌────▼───────┐                          ┌─────────▼──┐
              │     │ COMPLETED  │                          │  RETURNING │
              │     └────────────┘                          └─────┬──────┘
              │                                                   │
              └──────────► CANCELLED ◄────────────────────── RETURNED
                                │
                          (any state) ──► DISPUTED ──► resolution ──► COMPLETED
                                                                  └─► REFUNDED
```

**Terminal states:** `COMPLETED`, `CANCELLED`, `EXPIRED`, `RETURNED`, `REFUNDED`.

**Guards on key transitions:**

| Transition | Guard |
|---|---|
| `POSTED → MATCHED` | Trip capacity reserved atomically; carrier verified and active; handling capability match; COD headroom sufficient (BR-908) |
| `AWAITING_PICKUP → PICKED_UP` | Valid pickup proof (QR token, or OTP hash match, or agent confirmation); actor is the assigned carrier or agent |
| `OUT_FOR_DELIVERY → DELIVERED` | Valid dropoff proof; COD amount recorded if COD; geo within tolerance of destination or explicitly flagged |
| `DELIVERED → COMPLETED` | **Primary:** recipient confirms receipt (deck: *"dilepaskan apabila penerima mengesahkan barang sampai"*). **Fallback:** `now() ≥ delivered_at + settlement_window` with no confirmation. Either path requires no open dispute. Triggers settlement posting. |
| `MATCHED → PROCURING` | `BELI` only. Carrier has accepted; goods budget is in escrow. |
| `PROCURING → PICKED_UP` | Actual goods cost recorded and `≤ budget_cap`, **or** a linked approved `price_variance` exists (BR-913); receipt photo attached. |
| `PROCURING → PROCUREMENT_FAILED` | Goods unavailable, or variance declined, or variance timed out. Full goods refund posted. |
| `* → CANCELLED` | Actor permitted at that state; cancellation policy evaluated; capacity released; refund posted if prepaid |
| `* → DISPUTED` | Dispute window open; freezes escrow release |

**Enforcement.** `deliveries` has **no UPDATE policy for any client role** and `UPDATE` is revoked at grant level. The only writer is `internal.fn_delivery_transition(...)`, which:

1. Locks the delivery row (`FOR UPDATE`).
2. Looks up `(from_state, event, actor_role)` in `ref.delivery_transition_rules` — unknown combinations raise.
3. Evaluates the guard for that rule.
4. Writes the new state and appends an immutable `delivery_events` row.
5. Emits side effects through the transactional outbox (notification, settlement, capacity release).

Steps 1–5 are one transaction. There is no partial transition.

### 5.2 Order

```
CREATED → PENDING_PAYMENT → PAID → ACCEPTED → PREPARING → READY_FOR_PICKUP
        → (linked delivery lifecycle) → FULFILLED → SETTLED
```
Failure branches: `PAYMENT_FAILED`, `EXPIRED` (payment TTL), `REJECTED_BY_SELLER`, `CANCELLED`, `REFUNDED`, `PARTIALLY_REFUNDED`.

Rules: stock reserved at `PENDING_PAYMENT` with TTL; released on `PAYMENT_FAILED`/`EXPIRED`; committed at `PAID`. `SETTLED` is written only by the settlement engine.

### 5.3 Payment

```
INITIATED → PENDING → { AUTHORIZED → CAPTURED | SUCCEEDED } → SETTLED
                    → FAILED | CANCELLED | EXPIRED
CAPTURED/SUCCEEDED → REFUND_PENDING → REFUNDED | PARTIALLY_REFUNDED
```

**COD variant:** `COD_PENDING → COD_COLLECTED → COD_REMITTED → SETTLED`, with `COD_SHORTFALL` when remitted < collected.

Transitions are driven **only** by verified webhooks or by the COD reconciliation flow. Each state has a numeric precedence; a webhook carrying a lower-precedence state than the current one is recorded and ignored, which makes out-of-order delivery safe.

### 5.4 Payout

```
REQUESTED → UNDER_REVIEW → APPROVED → BATCHED → PROCESSING → PAID
                         → REJECTED
                                      PROCESSING → FAILED → (retry) → BATCHED
```
Maker/checker: above a configured threshold, `APPROVED` requires a different admin from the reviewer. Enforced by constraint (`approved_by <> reviewed_by`) and by RLS on the admin role.

### 5.5 Trip

```
DRAFT → ANNOUNCED → BOARDING → DEPARTED → IN_PROGRESS → ARRIVED → CLOSED
      → CANCELLED (releases all held capacity, re-posts affected Kirim)
```
`BOARDING` is the window in which capacity may be reserved. `DEPARTED` freezes the manifest; late additions require an explicit reopen event.

### 5.6 Verification (seller / carrier / agent)

```
NOT_STARTED → SUBMITTED → UNDER_REVIEW → { APPROVED(tier) | REJECTED(reason) | MORE_INFO_REQUIRED }
APPROVED → SUSPENDED → { APPROVED | REVOKED }
```

### 5.7 Dispute

```
OPEN → UNDER_REVIEW → AWAITING_EVIDENCE → DECIDED
     → RESOLVED_{REFUND_FULL | REFUND_PARTIAL | REJECTED | SPLIT} → CLOSED
```
Opening a dispute sets `escrow_hold = true` on the related settlement. Closing releases it. SLA timers per state drive the admin queue ordering.

---

## 6. Route matching engine

### 6.1 The core modelling decision

Live routing APIs are the wrong tool here. Rural Sabah's road network is sparse and often singular — between two settlements there is frequently exactly one viable road. Polyline matching against a road graph is expensive, requires connectivity, produces false precision on gravel and seasonal roads, and cannot express local knowledge such as "that road floods in December" or "you need a 4WD past Kg. Tinangol".

Instead, matching runs on a **curated corridor graph**:

- `route_nodes` — towns, junctions, jetties, kampung hubs. Each has a point geometry and a type.
- `route_edges` — a directed connection between two nodes with `distance_km`, `typical_minutes`, `road_quality`, `min_vehicle_class`, `is_seasonal`.
- A **trip** is an ordered node sequence: `[KK, Tamparuli, Ranau, Kundasang]`.
- A **Kirim** resolves to `(origin_node, destination_node)` via nearest-node resolution from its addresses.

Matching becomes an ordered-subsequence test with a detour allowance — cheap, deterministic, index-friendly, and offline-explainable.

### 6.2 Matching algorithm

```
match(kirim, trip):

  0. HARD FILTERS  (SQL WHERE — must be indexable, must eliminate ≥99%)
     trip.status = 'ANNOUNCED' or 'BOARDING'
     trip.depart_at within kirim pickup window (± slack)
     trip remaining_weight  ≥ kirim.billable_weight
     trip remaining_volume  ≥ kirim.volume
     trip remaining_parcels ≥ 1
     trip.handling_capabilities ⊇ kirim.handling_flags
     vehicle_class ≥ max(min_vehicle_class of edges on the required path)
     if kirim.is_cod: trip.accepts_cod AND carrier COD headroom ≥ cod_amount
     carrier.status = 'ACTIVE' AND carrier ≠ kirim.requester      -- BR-910
     carrier not blocked by requester, and vice versa

  1. CORRIDOR FIT
     origin_idx  = position of nearest trip node to kirim.origin_node
     dest_idx    = position of nearest trip node to kirim.destination_node
     require origin_idx < dest_idx                    -- direction matters
     on_corridor = both nodes are ON the trip's node list

  2. DETOUR (when not exactly on-corridor)
     detour_km = dist(kirim.origin, nearest corridor node)
               + dist(kirim.destination, nearest corridor node)
     reject if detour_km > carrier.max_detour_km (default 10, 25 for 4WD)

  3. SCORE  (0–100, server-computed, weights in app_config)
     corridor_fit      35   on-corridor = 35; else 35 * (1 - detour/max_detour)
     capacity_fit      15   how well the parcel fills without blocking bigger cargo
     timing_fit        15   overlap of pickup window and departure window
     carrier_quality   15   rating, completion rate, on-time rate
     price_fit         10   offered fee vs system quote
     locality_bonus    10   carrier's home community == origin or destination

  4. RANK, LIMIT 20, cache in match_results (TTL 5 min, invalidated on
     capacity change or state change of either side)
```

The same function serves both directions of the board: *cargo for a trip* and *trips for a cargo*. Only the anchor changes.

### 6.3 Distance

`route_edges.distance_km` is the authoritative distance for **pricing** — it is curated, stable and auditable, and prices must not fluctuate with a third-party API. PostGIS great-circle distance is used only for *nearest-node resolution* and *detour estimation*, never for money.

Path distance between two nodes on a corridor is precomputed into `ref.node_distance_matrix` (materialised, refreshed when edges change). For a graph of a few thousand nodes this is trivially small and makes quoting an index lookup rather than a graph traversal.

### 6.4 Capacity reservation — how overbooking is made impossible

Three independent layers. Any one of them alone would usually be enough; all three are required because the failure is unrecoverable in the physical world (a parcel that does not fit on the truck).

**Layer 1 — Serialisation.** Reservation happens inside `internal.fn_reserve_capacity(trip_id, delivery_id, weight, volume, parcels)`, which begins with `SELECT ... FROM trips WHERE id = $1 FOR UPDATE`. Concurrent bookings for the same trip serialise on that row lock. Different trips do not contend.

**Layer 2 — Database constraint.** `trips` carries denormalised `reserved_*` columns maintained by a trigger on `trip_reservations`, with:

```sql
CHECK (reserved_weight_grams  <= capacity_weight_grams)
CHECK (reserved_volume_cm3    <= capacity_volume_cm3)
CHECK (reserved_parcels       <= capacity_parcels)
```

If the function is ever wrong, or a future migration introduces a second write path, the transaction aborts. The invariant does not depend on anyone remembering it.

**Layer 3 — Holds with TTL.** Reservations enter as `HELD` with `expires_at`. Confirmation on `MATCHED` promotes to `CONFIRMED`. A `pg_cron` job releases expired holds every minute. This matters specifically because of the network environment: a carrier who accepts cargo and then loses signal mid-flow must not permanently consume capacity.

`ORDER BY` on reservation is by `created_at` — first confirmed wins, no reordering.

---

## 7. Payment and money architecture

### 7.1 Ledger design

All value movement is recorded as balanced double-entry transactions in the **`internal` schema**, which is *not exposed to PostgREST*. Clients cannot read or write it under any JWT. They see a filtered, read-only view.

**Accounts** (`internal.ledger_accounts`):

| Kind | Type | Examples |
|---|---|---|
| User | Liability | `CARRIER_PAYABLE:{id}`, `SELLER_PAYABLE:{id}`, `AGENT_PAYABLE:{id}`, `CUSTOMER_CREDIT:{id}` |
| User | Asset | `CARRIER_CASH_RECEIVABLE:{id}` (COD cash the carrier is holding) |
| System | Asset | `GATEWAY_CLEARING`, `BANK_OPERATING` |
| System | Liability | `ESCROW_HELD`, `PAYOUT_PAYABLE`, `TAX_PAYABLE` |
| System | Revenue | `PLATFORM_COMMISSION`, `DELIVERY_MARGIN` |
| System | Expense | `PROMO_EXPENSE`, `GATEWAY_FEES`, `WRITE_OFF` |

**Invariant:** for every `ledger_transaction`, `Σ debits = Σ credits`. Enforced by a `CONSTRAINT TRIGGER ... DEFERRABLE INITIALLY DEFERRED` that fires at commit. A transaction that does not balance cannot be committed — not by the settlement engine, not by an admin tool, not by a migration.

`ledger_entries` are append-only: `UPDATE` and `DELETE` are revoked from every role including `service_role`. Corrections are made by posting a reversing transaction, which preserves history.

### 7.2 Prepaid flow

```
1. Quote         fn_quote(...) → signed quote, TTL 15 min, pricing_rule_version pinned
2. Checkout      order created; stock reserved; payment INITIATED (idempotency key)
3. Gateway       hosted checkout / DuitNow QR — no card data ever touches our systems
4. Webhook       signature verified → recorded → processed exactly once
                 DR Gateway Clearing        RM 55.00
                   CR Escrow Held                       RM 55.00
5. Delivery      ... executes ...
6. Settlement    at DELIVERED + window, no dispute:
                 DR Escrow Held             RM 55.00
                   CR Seller Payable                    RM 36.80
                   CR Carrier Payable                   RM 12.75
                   CR Agent Payable                     RM  1.00
                   CR Platform Commission               RM  4.45
7. Payout        DR Seller Payable  →  CR Payout Payable  →  CR Bank Operating
```

### 7.3 COD flow

COD inverts the risk: cash exists in the physical world before it exists in the system.

```
1. Delivery      COD amount fixed at MATCHED, from the pinned quote
2. Acceptance    carrier COD headroom checked (BR-908) — hard block if insufficient
3. Collection    at DELIVERED, carrier records cash received:
                 DR Carrier Cash Receivable  RM 55.00
                   CR Escrow Held                        RM 55.00
4. Settlement    as prepaid — carrier's earnings credited to Carrier Payable
5. Remittance    carrier pays platform via bank transfer or agent hub:
                 DR Bank Operating           RM 55.00
                   CR Carrier Cash Receivable            RM 55.00
6. Netting       payout = Carrier Payable − Carrier Cash Receivable
```

Controls: per-carrier float limit scaled by verification tier and history; remittance SLA with automatic suspension on breach; ageing report; shortfall path posting to `WRITE_OFF` with mandatory admin reason.

### 7.3a Kirim Beli — procurement escrow with a budget cap

This is the deck's primary flow and the most intricate money path in the system. The carrier spends the requester's money on their behalf, so escrow must cover an amount that is **not yet known** at payment time.

**The invariant that governs everything here:**

```
goods_escrow_held  =  actual_goods_cost  +  refund_to_requester
```

Escrow is taken at the **budget cap**, and the difference between the cap and what was actually spent is always returned. It is never revenue, never a tip, never silently converted to credit.

```
1. Quote        goods_budget_cap (≤ RM 250) + delivery_fee = order_total
                Platform commission = 25% of order_total  (confirmed)
                Requester pays order_total up front.

                Worked example — order_total RM 50:
                  goods budget cap    RM 35.00
                  delivery fee        RM 15.00
                  ─────────────────────────────
                  order total         RM 50.00
                  platform commission RM 12.50   (25% of 50.00)

2. Capture      DR Gateway Clearing              RM 50.00
                  CR Escrow Held — Goods                    RM 35.00   (the cap)
                  CR Escrow Held — Delivery                 RM 15.00

3. Purchase     Carrier buys at the market. Records actual cost + receipt photo.
                Actual = RM 28.00.

   3a. IF actual > cap  ──►  PRICE VARIANCE (see below). Never auto-approved.

4. Delivery     Handover proof as normal. Recipient confirms receipt.

5. Settlement   DR Escrow Held — Goods           RM 35.00
                  CR Carrier Payable (reimbursement)        RM 28.00   ← at cost
                  CR Requester Refund Payable               RM  7.00   ← unspent, returned
                DR Escrow Held — Delivery        RM 15.00
                  CR Platform Commission                    RM 12.50   ← 25% of order total
                  CR Carrier Payable (earning)              RM  2.50

                Carrier receives RM 30.50 total: RM 28.00 replaces their outlay,
                RM 2.50 is service earnings.

6. Refund       RM 7.00 returned to original method, or to wallet credit with
                explicit consent. Never defaulted to credit.
```

**Two consequences the founders should see in the numbers.**

*Commission is levied on the whole order, including goods.* On a high-value purchase the platform's take scales with grocery price even though the delivery costs the same to perform — 25% of a RM 200 fish order is RM 50 of commission on the same physical journey as a RM 20 order. `commission_rules.max_commission_sen` exists so a cap can be introduced later without a migration; it is left `NULL` at launch to match the deck exactly.

*Carrier service earnings are thin per parcel by design.* RM 2.50 on the worked example only works because the Beluran↔KK trip is **already happening** and the carrier is filling empty space — which is precisely the Kirim Balik thesis. Ten parcels on one run is RM 25 of pure margin on fuel the carrier was burning anyway. The consequence for the product is that **trip fill rate is the metric that makes carrier supply viable**, not fee per parcel. It is tracked as a first-class metric (`PRD.md` §11).

**Price variance flow** (actual > cap). This is the interaction the deck promises with *"Kalau harga pasar lebih tinggi, kita akan hubungi awak."*

```
Carrier at market  →  submits actual_price + photo  →  price_variance PENDING
                                │
                      notify requester: push → SMS after 5 min
                                │
        ┌───────────────────────┼───────────────────────┐
     APPROVE                REDUCE_QTY               DECLINE
        │                       │                       │
  top-up charged          buy less within cap    PROCUREMENT_FAILED
  (new payment,           actual ≤ cap           full goods refund;
   idempotent)                                   delivery fee per policy
        │                       │                       │
        └───────────────────────┴───────────────────────┘
                                │
                    TIMEOUT (default 2h, configurable)
                                │
                      → DECLINE  (safe default: do not spend)
```

The timeout defaults to **not spending**. A requester who is out of coverage — which is the normal condition in this market — must never come back online to discover that money was spent without their agreement.

**Carrier exposure.** Until reimbursement settles, the carrier is out of pocket. `internal.ledger_accounts` tracks `CARRIER_PROCUREMENT_ADVANCE:{id}` and the same float mechanism that caps COD exposure (BR-908) caps this. A carrier cannot accept more concurrent `BELI` value than their tier permits.

**Fraud surface.** This flow is the most attackable in the product: inflated receipts, collusion between requester and carrier, phantom purchases. Controls: receipt photo mandatory with EXIF and geo, actual cost compared against a rolling median for that category and corridor, variance-approval rate monitored per carrier pair, and repeat requester↔carrier pairings surfaced to the risk queue. See `SECURITY.md`.

### 7.4 Pricing engine

**Distance is banded, not metered.** This is the single most consequential pricing decision in the product, and it follows directly from the Kirim Balik thesis: the carrier is *already* driving Beluran→KK. A parcel does not make the journey longer, so charging by the kilometre prices a cost that nobody incurs.

The numbers force the issue. At RM 0.45/km the 266 km corridor yields a RM 120 delivery fee against a deck order value of RM 50. Banding yields RM 15.50, an RM 50.50 order and RM 12.63 commission — within 1 % of the deck's stated economics. Per-km pricing cannot be made to fit.

Pricing is a **server-only pure function** over versioned parameters:

```
billable_kg   = max(actual_kg, (L×W×H cm) / volumetric_divisor)
corridor_km   = ref.node_distance_matrix[origin_node][dest_node]
band          = band_for(corridor_km)   -- local | district | regional | long_haul

delivery_fee = base_fare
             + corridor_band_sen[band]                    -- NOT per-km
             + per_kg_rate × max(0, billable_kg − included_kg)
             + Σ handling_surcharges(flags)
             + cod_handling_fee (if COD)
             − promotion_discount

order_total     = goods_budget + delivery_fee
commission      = order_total × platform_commission_bps / 10000   -- 25%
carrier_earning = delivery_fee − commission − agent_fee
```

Every quote persists `pricing_rule_version`, the full input snapshot and the computed breakdown. A price can be reconstructed and explained months later. Rate changes are new `pricing_rules` rows with `effective_from` — never edits, so historical quotes remain reproducible.

The client receives only the breakdown and total. It has no formula and no coefficients.

### 7.5 Webhook idempotency

```
POST /webhooks/payment/{provider}
  1. Read raw body (before any parsing)
  2. Verify HMAC signature against the raw bytes — reject 401 on mismatch
  3. INSERT INTO internal.webhook_events (provider, provider_event_id, payload, ...)
     ON CONFLICT (provider, provider_event_id) DO NOTHING
     → 0 rows affected  ⇒  already seen  ⇒  return 200 immediately
  4. BEGIN
       lock the payment row FOR UPDATE
       if incoming_state_precedence <= current_state_precedence:
            mark webhook 'IGNORED_OUT_OF_ORDER'; COMMIT; return 200
       apply transition; post ledger entries; enqueue notifications
       mark webhook 'PROCESSED'
     COMMIT
  5. Return 200 (always 200 on a well-formed, verified event — retries are for
     genuine failures only)
```

The unique constraint on `(provider, provider_event_id)` is what makes this safe. It is a database guarantee, not application logic, so it survives concurrent deliveries of the same webhook to two Edge Function instances.

Unprocessable events are stored with `status='FAILED'` and replayed from the admin console. Nothing is dropped.

### 7.6 Client-side idempotency

Every mutating request carries `Idempotency-Key: <uuid v4>`, generated when the *user acts* — not when the request is sent. A queued action retried after four days on a flaky connection carries the same key it was born with.

Server behaviour: `internal.idempotency_keys` stores `(key, actor, endpoint, request_hash, response_body, status, expires_at)` with a 24 h TTL. Same key + same hash → replay the stored response. Same key + different hash → `409 IDEMPOTENCY_KEY_REUSE`.

---

## 8. QR and OTP handover

### 8.1 Why two mechanisms plus two fallbacks

A single proof mechanism excludes real users in this market: the recipient may have no smartphone, no signal, no charge, or no literacy in the app's language. The ladder degrades gracefully without ever degrading to "the carrier just says it happened".

| Rank | Method | Requires | Offline | Trust |
|---|---|---|---|---|
| 1 | **QR scan** | Recipient displays a code (screen or printed slip) | ✅ full | Highest — cryptographic |
| 2 | **OTP** | Recipient reads 6 digits aloud from SMS or a slip | ✅ full | High — shared secret |
| 3 | **Agent confirmation** | Verified agent at a community hub | ✅ full | High — accountable human |
| 4 | **Photo POD + geotag** | Camera only | ✅ full | Low — auto-flags for review |

Method 4 never closes a delivery cleanly on its own: it sets `proof_quality='WEAK'`, delays settlement to the extended window, and enters the review queue.

### 8.2 QR token design

Tokens must be verifiable by the *server* after an offline scan — the scanner has no connectivity at scan time and cannot validate anything itself.

```
kk1.<base64url(payload)>.<base64url(ed25519_signature)>

payload = {
  v: 1,
  d: "<delivery_id>",
  l: "pickup" | "dropoff",
  c: "<handover_code_id>",
  n: "<128-bit nonce>",
  iat, exp
}
```

- Signed with an **Ed25519** key held in Supabase Vault. Compact signature (64 bytes) keeps the QR at low density — important because it will be scanned from cracked screens and printed slips in bad light.
- The QR is **displayed by the party handing over** and **scanned by the party receiving custody**.
- The scanner stores the raw token locally and submits it when connectivity returns.
- Server verification: signature valid → not expired → `nonce` unseen (unique index on `handover_nonces.nonce`) → binds to the correct delivery, leg and actor → transition executes.

**Replay:** first use wins, enforced by the unique index. A screenshotted QR submitted twice fails the second time, and the second attempt is recorded as a risk signal.

**Offline print fallback:** the agent hub can print a slip carrying both the QR and the OTP, so a recipient with no phone at all can still complete a verified handover.

### 8.3 OTP handover design

- 6 numeric digits, generated server-side with a CSPRNG.
- Stored as `HMAC-SHA256(code, pepper)` where the pepper lives in Vault — never as plaintext, never reversibly encrypted.
- Delivered by push, in-app, and SMS fallback for critical legs.
- Max 5 attempts, then the code locks and must be rotated by the requester.
- Rate limited per delivery, per actor and per device.
- Verified offline-capable: the carrier's device caches only the **hash** for the current leg, compares locally to give instant feedback, and still submits the entered code for authoritative server verification. A locally "valid" code that fails server verification reverses the optimistic UI and raises a risk signal.

### 8.4 Geo and time integrity

Every proof records `client_captured_at`, `server_received_at`, `device_geo`, `accuracy_m`, and Android's mock-location flag. The server computes distance from the expected node. Outside tolerance, or mock location detected, or clock skew beyond a threshold → `proof_quality='SUSPECT'`, settlement delayed, review queue entry. The delivery is not blocked — rural GPS is genuinely unreliable and blocking would punish honest users — but it is not silently trusted either.

---

## 9. Offline architecture

### 9.1 Layers

```
┌───────────────────────────────────────────────────────────────┐
│ UI                    optimistic render + explicit pending badge│
├───────────────────────────────────────────────────────────────┤
│ TanStack Query        memory cache, stale-while-revalidate      │
├───────────────────────────────────────────────────────────────┤
│ Repository            single read/write path, cache-first       │
├───────────────────────────────────────────────────────────────┤
│ SQLite (WAL)          entity cache + outbox + media queue       │
├───────────────────────────────────────────────────────────────┤
│ Sync engine           pull (delta) · push (outbox) · scheduler  │
├───────────────────────────────────────────────────────────────┤
│ Transport             retry/backoff · idempotency · compression │
└───────────────────────────────────────────────────────────────┘
```

### 9.2 Outbox

```sql
-- local SQLite
CREATE TABLE outbox (
  id               TEXT PRIMARY KEY,
  created_at       INTEGER NOT NULL,
  endpoint         TEXT NOT NULL,
  method           TEXT NOT NULL,
  payload          TEXT NOT NULL,          -- JSON
  idempotency_key  TEXT NOT NULL UNIQUE,   -- born at user action
  depends_on       TEXT REFERENCES outbox(id),
  entity_type      TEXT NOT NULL,
  entity_id        TEXT NOT NULL,
  attempts         INTEGER NOT NULL DEFAULT 0,
  next_attempt_at  INTEGER NOT NULL,
  status           TEXT NOT NULL,          -- PENDING|SENDING|SENT|FAILED|CONFLICT
  last_error       TEXT
);
CREATE INDEX ix_outbox_ready ON outbox(status, next_attempt_at);
```

- **Ordering** is per-entity, not global. Deliveries for trip A do not block trip B. `depends_on` encodes the few genuine orderings (pickup before delivery).
- **Backoff**: 2^attempts seconds, capped at 5 minutes, with ±20 % jitter to prevent thundering herds when a village's tower comes back.
- **Give-up**: after 10 attempts or 7 days, the item moves to `FAILED` and surfaces in a user-visible "needs attention" list. Never silently discarded.
- **Media** is queued separately with lower priority — a POD photo must never delay the delivery-state event it accompanies. The event references the media by local id; the server accepts the event and attaches the photo when it arrives.

### 9.3 Delta pull

```
GET /sync/pull?since=<iso8601>&tables=deliveries,orders,notifications&limit=200
→ { changes: {...}, cursor: "<new_since>", has_more: bool, server_time: "..." }
```

- Every synced table carries `updated_at timestamptz` and `deleted_at` (soft delete), with an index on `(updated_at)`.
- Cursor stored per table in SQLite; pages capped so a long-offline device recovers incrementally rather than in one huge response on a 3G link.
- Scope is always the caller's own data, enforced by RLS — the sync endpoint is not privileged.

### 9.4 Conflict policy

| Data class | Policy | Rationale |
|---|---|---|
| Delivery/order/payment state | **Server always wins**, unconditionally | Server owns the state machine |
| Money | Server only; client never writes | BR-900 |
| Handover proofs | Append-only; server dedupes by nonce/idempotency key | Two scans of the same handover must produce one effect |
| Profile, addresses, drafts | Last-write-wins on `updated_at` | Low-stakes, user-owned |
| Product edits (seller) | Field-level merge; conflicts surfaced for manual resolution | Two devices editing one catalogue |
| Chat messages | Append-only, ordered by server timestamp, client id for dedupe | Natural CRDT |

When the server rejects a queued mutation because the state moved on (a customer cancelled while the carrier was offline), the client does not silently drop it — it produces an explicit reconciliation notice: *"Kiriman ini telah dibatalkan semasa anda di luar talian."*

### 9.5 Storage budget

| Bucket | Cap | Eviction |
|---|---|---|
| Entity cache | 30 MB | Age + access recency |
| Images | 100 MB | LRU |
| Outbox media (pending) | 20 MB | **Never evicted** — blocks new capture instead, with a clear warning |
| **Total** | **150 MB** | Enforced after every write; user-visible in Settings |

Pending outbox media is deliberately un-evictable: losing a proof photo is worse than refusing to take a new one.

---

## 10. Notification architecture

```
DB event / transition
      │
      ▼
transactional outbox (internal.notification_outbox)   ← same transaction as the state change
      │
      ▼
Edge Function `dispatch-notifications` (pg_cron, every 30 s + realtime nudge)
      │
      ├──► In-app inbox row               ← SOURCE OF TRUTH, always written
      ├──► Expo Push → FCM v1             ← best effort
      └──► SMS fallback                   ← critical only, if unacknowledged after N min
```

**Why the outbox.** Emitting a push directly from a transition function would either send a notification for a transaction that later rolled back, or lose the notification if the send failed. Writing to an outbox table inside the same transaction makes notification delivery exactly as durable as the state change that caused it.

**Why the in-app inbox is authoritative.** Budget Android devices in this market — Xiaomi, Oppo, Vivo, Realme, Infinix, Tecno — ship aggressive battery managers that kill background app processes and silently suppress FCM. Push cannot be relied upon. The inbox always has the truth; push is an accelerator. See `ANDROID.md` §6 for the OEM-specific onboarding guidance.

**Channels** (Android 8+): `delivery_critical` (HIGH), `handover_codes` (HIGH), `payments` (HIGH), `orders` (DEFAULT), `chat` (DEFAULT), `promotions` (LOW). Separate channels let a user mute promos without muting the code they need to receive a parcel.

**Token lifecycle:** registered on login and on token refresh; deactivated on `DeviceNotRegistered` receipts; pruned after 60 days idle. Receipts are polled and recorded, which is also how the SMS fallback decides to fire.

---

## 11. Realtime

Used sparingly. Realtime is a poor fit for an unstable-network product: reconnection storms cost data and battery.

| Use | Transport | Reason |
|---|---|---|
| Chat messages | Realtime (Postgres Changes, RLS-filtered) | Genuinely interactive |
| Delivery status on the tracking screen | Realtime **while the screen is foregrounded**, polling otherwise | Bounded subscription lifetime |
| Carrier location on tracking | Polling every 30–60 s, not Realtime | Cheaper; precision is not needed |
| Board updates | Pull-to-refresh + push | Constant churn would burn data |
| Admin dashboards | Realtime | Office connectivity |

Realtime subscriptions are torn down on background and re-established with backoff on foreground.

---

## 12. Storage architecture

| Bucket | Public | Contents | Access |
|---|---|---|---|
| `product-images` | ✅ | Marketplace imagery | Public read; write restricted to the owning seller |
| `avatars` | ✅ | Profile pictures | Public read; owner write |
| `address-photos` | ❌ | Destination landmark photos | Signed URL, 1 h, delivery counterparties only |
| `pod` | ❌ | Proof-of-delivery photos | Signed URL, 1 h, counterparties + admin |
| `kyc` | ❌ | MyKad, licences, vehicle docs | Signed URL, **15 min**, compliance admins only, every access audited |
| `dispute-evidence` | ❌ | Dispute attachments | Signed URL, 1 h, dispute parties + admin |
| `chat-media` | ❌ | Chat images | Signed URL, 1 h, conversation participants |

Path convention `{user_id}/{entity_id}/{uuid}.{ext}` with RLS policies asserting `(storage.foldername(name))[1] = auth.uid()::text` for owner-write buckets.

All display images are served through Storage image transforms at fixed widths (`w=160` thumb, `w=480` card, `w=1080` detail). The app never requests an original.

---

## 13. Scheduled work

| Job | Cadence | Purpose |
|---|---|---|
| `expire_capacity_holds` | 1 min | Release `HELD` reservations past TTL |
| `expire_offers` | 1 min | Close offers past TTL, release capacity |
| `expire_quotes` | 5 min | Mark quotes expired |
| `expire_kirim` | 5 min | Auto-expire unmatched requests, notify |
| `dispatch_notifications` | 30 s | Drain notification outbox |
| `notification_sms_fallback` | 5 min | Escalate unacknowledged critical notifications |
| `settle_completed_deliveries` | 10 min | `DELIVERED` + window + no dispute → `COMPLETED` + settlement posting |
| `release_stock_reservations` | 1 min | Expired unpaid checkouts |
| `reconcile_ledger` | Daily 02:00 | Assert Σdebits = Σcredits globally and per account type; page on variance |
| `cod_ageing_report` | Daily | Flag carriers past remittance SLA; auto-suspend on breach |
| `refresh_node_distance_matrix` | On edge change + weekly | Keep quoting distances current |
| `rebuild_rating_summaries` | Daily | Drift check against incremental aggregates |
| `prune_tracking_points` | Daily | Drop location history > 30 days |
| `prune_idempotency_keys` | Hourly | TTL cleanup |
| `risk_rules_sweep` | 15 min | Recompute risk scores, enqueue reviews |

All jobs take a `pg_advisory_xact_lock` on a job-specific key so overlapping runs are impossible, and record start/end/outcome in `internal.job_runs`.

---

## 14. Admin console architecture

- **Next.js App Router**, React Server Components. Data fetching happens on the server with the `service_role` key; that key never crosses to the browser.
- Every admin mutation goes through a Server Action that: authenticates, authorises against the admin role, executes, and writes an `audit.audit_logs` row in the **same transaction**. Audit is not a side effect — an action whose audit write fails does not commit.
- **Roles:** `admin_support` (read + comms), `admin_ops` (deliveries, verification), `admin_finance` (payouts, refunds, reconciliation), `admin_compliance` (KYC, fraud, data requests), `admin_super` (role management only — deliberately *not* a superset of the others, so no single account both moves money and grants itself the right to).
- Access requires email + password + **mandatory TOTP MFA**. Sessions are short (8 h) with re-authentication for destructive actions.
- Deployed to Vercel; preview deployments are protected and point at the staging Supabase project only.

---

## 15. Observability

| Signal | Tool | Alert |
|---|---|---|
| Mobile crashes / ANR | Sentry + Play Vitals | Crash-free < 99 %; ANR > 0.4 % |
| Edge Function errors | Sentry + Supabase logs | Error rate > 2 % over 5 min |
| Payment failures | Custom metric | Failure rate > 10 % over 15 min |
| Webhook lag | `received_at → processed_at` | p95 > 60 s |
| **Ledger imbalance** | Daily reconciliation | **Any variance → immediate page** |
| Capacity constraint violation | Postgres error counter | **Any occurrence → page** (means a bug reached Layer 2) |
| COD exposure | Rolling sum | Total outstanding > threshold |
| Match rate | Product metric | < 50 % over 24 h |
| Outbox depth (client) | Telemetry | p95 > 20 items suggests a sync defect |
| DB connections / slow queries | Supabase metrics | Pool > 80 %; queries > 2 s |

Correlation: `X-Request-Id` is generated on the client, echoed by every layer, attached to Sentry events and written to `audit_logs`. One id traces a tap on a phone in Kudat through Edge, Postgres and the gateway.

---

## 16. Failure modes and responses

| Failure | Detection | Response |
|---|---|---|
| Gateway down | Health check + error rate | Disable prepaid methods via feature flag; COD remains available; banner in app |
| SMS provider down | Delivery receipts | Fail over to WhatsApp channel; extend OTP TTL |
| Push (FCM) degraded | Receipt failures | SMS fallback threshold lowered automatically |
| Postgres saturated | Connection pool metric | Shed load on non-critical reads (board, analytics); protect money and handover paths |
| Edge Function cold-start spike | p95 latency | Increase client timeout tolerance; ensure money paths retry idempotently |
| Carrier device offline mid-trip | No events for N hours | Notify customer with an honest status; support outreach; no automatic state change |
| Ledger imbalance | Daily job | Halt payout batches, page finance, freeze settlement until reconciled |
| Mass reconnection after outage | Request spike | Client jitter + server rate limits absorb it |

---

## 17. Architecture decision record (summary)

| # | Decision | Status | Consequence |
|---|---|---|---|
| ADR-01 | Supabase-native; no separate app server | Accepted | Invariants in DB; accept Edge cold starts |
| ADR-02 | Double-entry ledger in an unexposed `internal` schema | Accepted | More upfront work; correct COD/commission/refunds |
| ADR-03 | Curated route-node graph, no live routing API | Accepted | Requires ground curation; gains determinism, offline explainability, zero per-quote cost |
| ADR-04 | Server-held cart and signed quotes | Accepted | More round trips; removes price tampering |
| ADR-05 | Ed25519 offline-verifiable QR + hashed OTP ladder | Accepted | Key management needed; handover works with zero signal |
| ADR-06 | Foreground service tracking, no background location | Accepted | Tracking only while the app is active; avoids Play sensitive-permission review |
| ADR-07 | SQLite outbox with birth-time idempotency keys | Accepted | Client complexity; exactly-once semantics over bad networks |
| ADR-08 | In-app inbox authoritative, push best-effort | Accepted | Extra surface; survives OEM battery managers |
| ADR-09 | Capacity protected by lock + CHECK constraint + TTL holds | Accepted | Slight write contention per trip; overbooking structurally impossible |
| ADR-10 | Android-only; no cross-platform abstraction | Accepted | iOS would need real work later; MVP is leaner now |
| ADR-11 | Realtime limited to chat and foregrounded tracking | Accepted | Less "live"; large data and battery saving |
| ADR-12 | `admin_super` cannot move money | Accepted | More admin accounts; no single point of total compromise |
| ADR-13 | Kirim is typed (`BELI` / `HANTAR` / `PASARAN`) rather than parcel-only | Accepted | Matches the deck's actual flow; adds a procurement money path |
| ADR-14 | Platform commission **25 % of order total** (goods budget + delivery fee); goods reimbursed to carrier at cost | Accepted (confirmed) | Matches deck arithmetic (RM 50 × 25 % = RM 12.50). Commission scales with goods value; `max_commission_sen` reserved for a future cap. Makes trip fill rate, not per-parcel fee, the driver of carrier viability. |
| ADR-15 | Unspent budget always refunded; price variance defaults to **not spending** on timeout | Accepted | More refund traffic; protects users who are offline at the moment of decision |
| ADR-16 | Escrow releases on recipient confirmation, timer as fallback | Accepted | Matches the deck's trust promise without stranding carrier earnings |
| ADR-17 | Procurement advance counted against the same carrier float limit as COD | Accepted | Caps carrier exposure and platform bad-debt in one mechanism |
| ADR-18 | **Muatan Jual is a core capability, built and gated — not shelved** | Accepted 2026-09-04 | BUILD → TEST → COMPLIANCE GATE → ACTIVATE. Four independent flags plus a `compliance_status` lifecycle; `internal.fn_marketplace_gate()` raises rather than returning empty, so a silent failure cannot be mistaken for a bug and "fixed" by removing the check |
| ADR-19 | **Geography is configuration: `regions → districts → mukims → service_areas → pickup_points`** | Accepted 2026-09-04 | Opening a district is an admin `UPDATE` to `service_areas.status`, never an Android release. Beluran/Paitan/KK `PILOT`, other Sabah districts `PLANNED` |
| ADR-20 | **`BOAT` is a first-class transport type** | Accepted 2026-09-04 | Paitan's corridor includes a river edge with `min_vehicle_type='BOAT'`. Affects route capability, capacity, scheduling, matching, tracking and delivery-state handling — not an edge case bolted on later |
| ADR-21 | Category compliance and licence expiry enforced server-side | Accepted 2026-09-04 | Compliance can close a category without a release; licence expiry blocks sales on the expiry date regardless of whether any notification was seen |

### 17.1 Verification status of this document

**No architecture described here has been executed.** Migrations `0000`–`0007`,
84 pgTAP assertions and 7 Edge Functions are written and statically reviewed
only; the verification gate (`supabase db reset && supabase test db`) could not
be run in the authoring environment. See `IMPLEMENTATION-GAP-REPORT.md` §0a for
the verbatim command output. Treat every mechanism above as *designed*, not
*proven*, until that gate is green.
