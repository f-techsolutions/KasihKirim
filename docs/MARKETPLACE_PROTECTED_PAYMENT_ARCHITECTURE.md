# KasihKirim — Marketplace, Protected Payment and Settlement Architecture

**Status:** AUDIT + PLAN, plus the P0 settlement correctness fix (§22) implemented in
`0024_order_settlement_allocations.sql`. No payment provider is integrated and no real money can
move: nothing creates a payment, and `prepaid_payments_enabled` remains `false`.
**Date:** 2026-09-10
**Audited against:** `main` @ `4ee993b` + branch `claude/android-cloud-build-pr-gate-jjgh33` @ `3390234`,
and the live Supabase project `oyaesfvgqsdqmxmosqsr` (schema, RLS, grants, function bodies and
`ref.app_config` read directly, not inferred from migration files).

**This is not legal advice.** Activation remains gated by `MUATAN-JUAL-COMPLIANCE.md` §8 (MJ-01),
which is still open with counsel.

---

## 0. Headline finding

**The protected-payment architecture is roughly 70% already built, and was designed for exactly
this model.** The payment state machine, double-entry ledger, escrow accounts, webhook replay
protection, idempotency, proof-of-delivery, dispute holds, commission rules, payout maker-checker
and the customer-confirmation transition all exist and are live.

What is missing is narrow and specific: **nothing ever creates a payment, nothing splits an order
payment into per-party allocations, and there is no seller payable leg anywhere.**

The single most important consequence:

> `internal.fn_settle_delivery` was written for Kirim. For an order-linked delivery it computed
> `refund = goods_budget - actual_goods`, found `actual_goods` NULL, and **credited the entire goods
> value to `REQUESTER_REFUND` — refunding the buyer instead of paying the seller.**

**Status: FIXED** in `0024_order_settlement_allocations.sql`. See §22.

The fix is proven by running `supabase/tests/15_order_settlement.test.sql` against the *original*
function: it fails with the buyer credited RM110 and the seller credited 0 —

```
not ok 22 - THE DEFECT: the buyer is not refunded the product value even though actual_goods_sen is NULL
#         have: 11000
#         want: 0
not ok 23 - THE FIX: the seller is paid from the allocation, not from budget arithmetic
#         have: 0
#         want: 10000
```

— and passes against the corrected function.

---

## 1. Business flow

```
SELLER lists product ──► product ACTIVE (admin moderated)
        │
CUSTOMER selects ──► order created ──► backend computes total
        │
     PAYMENT ──► provider ──► webhook ──► funds HELD
        │                                   │
        │                         allocations recorded:
        │                         seller / carrier / KasihKirim
        │
   delivery job ──► carrier matched ──► PICKED_UP ──► IN_TRANSIT
        │                                              │
        │                                    OUT_FOR_DELIVERY
        │                                              │
        │                              (proof required) DELIVERED
        │
CUSTOMER confirms  ──or──  auto-release window expires
        │
  settlement eligibility evaluated
        │
   SETTLEMENT ENGINE
     ├── seller payable   ──► seller available
     ├── carrier payable  ──► carrier available
     └── commission       ──► KasihKirim revenue
```

Customer-facing language is **"Bayaran dilindungi sehingga pesanan berjaya dihantar"** —
protected payment, deliberately *not* the word "escrow", which carries regulated meaning that the
provider structure does not yet support.

---

## 2. Product lifecycle

Already built (`0016`, `0017`, `0018`, `0023`).

```
draft ──► pending_review ──► active ──► paused ──► active
   ▲            │               │
   └── rejected ┘          delisted
```

- `rpc_create_product` / `rpc_update_product` — slug-resolved category, never a client-supplied id.
- Status is protected by `internal.tg_protect_product_moderation_columns`: a seller may only make
  the transitions above; `approved_by`, `approved_at`, `compliance_note` and `rejection_reason` are
  forced back to their old values for non-admins, on INSERT as well as UPDATE.
- `rpc_admin_set_product_status` (admin only) is the sole path to `active`.
- Ownership enforced by `products_write` RLS (seller's own rows only).

**Gap:** stock. `public.inventory` exists and `rpc_checkout` reserves against it, but there is no
seller-facing way to set it, and **a product with no inventory row sells without limit.**

## 3. Order lifecycle

`public.orders` + `public.order_items` exist with a price snapshot per line
(`title_snapshot`, `price_sen`, `quantity`, `line_total_sen`) — so a later seller price change
cannot alter an existing order. `rpc_checkout` (`0020`) groups a multi-seller cart into one order
per seller tied by `order_group_id`, prices from the live product row, and reserves stock inside
one transaction.

`ref.order_status` already models the full lifecycle:

```
CREATED ─► PENDING_PAYMENT ─► PAID ─► ACCEPTED ─► PREPARING
        ─► READY_FOR_PICKUP ─► FULFILLED ─► SETTLED
failure: PAYMENT_FAILED · EXPIRED · REJECTED_BY_SELLER · CANCELLED
         REFUNDED · PARTIALLY_REFUNDED
```

**Gap:** nothing ever moves an order past `CREATED`. There are no seller fulfilment transitions and
no payment step.

## 4. Payment lifecycle

`ref.payment_status` and `internal.payments` are live and complete:

```
INITIATED ─► PENDING ─► AUTHORIZED ─► CAPTURED/SUCCEEDED ─► SETTLED
failure:  FAILED · CANCELLED · EXPIRED
refund:   REFUND_PENDING ─► REFUNDED / PARTIALLY_REFUNDED
COD:      COD_PENDING ─► COD_COLLECTED ─► COD_REMITTED · COD_SHORTFALL
```

Out-of-order and replayed provider events are already handled properly:

- `internal.fn_status_precedence` ranks every status; a lower-ranked event is recorded as
  `IGNORED_OUT_OF_ORDER` and has no effect. Terminal failures rank *above* `pending`, so a late
  "pending" cannot revive a failed payment.
- `internal.webhook_events` has `UNIQUE (provider, provider_event_id)` — replay protection.
- `internal.payments` has `UNIQUE (provider, provider_ref)` and a unique `idempotency_key`.
- `fn_apply_payment_event` takes `FOR UPDATE` on the payment row, so two Edge instances handed the
  same event serialise.
- The capture ledger transaction uses `ON CONFLICT (idempotency_key) DO NOTHING`, so even a replay
  that reached the posting step cannot post twice.

**Gaps:**
- **Nothing creates a payment.** There is no `INSERT INTO internal.payments` in any migration or any
  of the 47 live functions. The table has no entry point.
- No payment provider is integrated. `provider` is free text; there is no Edge Function receiving
  webhooks (`rpc_record_webhook` exists as the landing point but nothing HTTP calls it).
- `payment_methods_enabled` in `ref.app_config` is `["COD"]`.

## 5. Delivery lifecycle

Unchanged and already correct. `ref.kirim_status` has the 20 documented states and **no `ACCEPTED`
state** — this must stay that way. Transitions are table-driven via
`ref.delivery_transition_rules (from_status, event) → to_status`, carrying `allowed_roles`,
`applies_to_types` (already including `PASARAN`), `requires_proof`, `proof_leg` and an as-yet
**unused `guard_function` column** — which is the natural place to hang settlement guards.

Relevant live rules:

| From | Event | To | Roles | Proof |
|---|---|---|---|---|
| `OUT_FOR_DELIVERY` | `CONFIRM_DELIVERY` | `DELIVERED` | carrier, agent | **required** |
| `DELIVERED` | `CONFIRM_RECEIPT` | `COMPLETED` | customer, agent | no |
| `DELIVERED` | `AUTO_SETTLE` | `COMPLETED` | admin_ops | no |

The delivery state machine never touches balances directly — `fn_delivery_transition` calls
`fn_settle_delivery` only on `CONFIRM_RECEIPT`. That separation is already correct per §6 of the
brief and must be preserved.

## 6. Settlement lifecycle

`internal.fn_settle_delivery` exists and already:

- refuses to settle while an unresolved dispute holds escrow (`ESCROW_HELD_BY_DISPUTE`);
- posts a balanced double-entry `SETTLEMENT` transaction with a unique idempotency key;
- splits the delivery fee into `PLATFORM_COMMISSION`, optional `AGENT_PAYABLE` and
  `CARRIER_PAYABLE`;
- marks the delivery `COMPLETED` and increments `carriers.completed_count`.

**Gaps:**
- **No `SELLER_PAYABLE` leg exists anywhere in the codebase.**
- It reads `kirim_requests.actual_goods_sen` and `quotes.goods_budget_sen` — a Kirim BELI shape.
  For a marketplace order this refunds the buyer the goods value (see §0).
- `settlement_window_hours = 48` is configured and an `AUTO_SETTLE` rule exists, but **nothing
  schedules it** — there is no job that sweeps `DELIVERED` deliveries past the window.
- Settlement eligibility is implicit (whatever `CONFIRM_RECEIPT` allows) rather than an explicit,
  testable predicate.

## 7. Financial allocation model

The required model — one payment split into per-party allocations that are held and then released —
maps onto the **existing double-entry ledger** and does not need a competing system.

Existing account codes in use: `GATEWAY_CLEARING`, `ESCROW_HELD_GOODS`, `ESCROW_HELD_DELIVERY`,
`PLATFORM_COMMISSION`, `CARRIER_PAYABLE:<carrier_id>`, `AGENT_PAYABLE`, `REQUESTER_REFUND:<user_id>`.
`internal.fn_post` resolves-or-creates an account and classifies it automatically;
`internal.ledger_accounts.owner_type` **already includes `'seller'`**.

Target for an RM130 order (RM100 goods, RM20 delivery, RM10 commission):

```
On capture (funds held)
  DEBIT   GATEWAY_CLEARING            13000
  CREDIT  ESCROW_HELD_GOODS           10000
  CREDIT  ESCROW_HELD_DELIVERY         3000

On settlement (funds released)
  DEBIT   ESCROW_HELD_GOODS           10000
  CREDIT  SELLER_PAYABLE:<seller>     10000     ← new leg
  DEBIT   ESCROW_HELD_DELIVERY         3000
  CREDIT  PLATFORM_COMMISSION          1000
  CREDIT  CARRIER_PAYABLE:<carrier>    2000
```

Invariant: `payment.amount_sen = seller + carrier + commission + explicit adjustments`, enforced
server-side, in `BIGINT` sen throughout. There is no floating point anywhere in the money path.

**Decision to make:** whether allocations are (a) derived from ledger balances per account, or
(b) additionally materialised in an `internal.payment_allocations` table. Recommendation: **(b) as a
declared intent record written at capture**, with the ledger remaining authoritative for balances.
The allocation row answers "what was this payment *for*" without replaying entries, which §22's
audit questions require, and it gives settlement a single row to check against.

## 8. Seller wallet

Does not exist. `internal.payouts.payee_type` already permits `'seller'`, and
`ledger_accounts.owner_type` already permits `'seller'` — the plumbing anticipates it.

Required split (§27): `PENDING` ("Menunggu penyelesaian pesanan") vs `AVAILABLE`
("Jumlah yang boleh dikeluarkan").

## 9. Carrier wallet

Exists as `rpc_my_earnings`, but **it is not ledger-derived**. It sums
`deliveries.carrier_earning_sen` filtered by delivery status:

- `available_sen` = sum where `status = 'COMPLETED'`
- `pending_sen` = sum where status in PICKED_UP/IN_TRANSIT/OUT_FOR_DELIVERY/DELIVERED
- `cod_held_sen`, `float_limit_sen` from `public.carriers`

**This ignores payouts entirely** — money already paid out still counts as "available" — and it does
not read `CARRIER_PAYABLE`. It is a display approximation, not a balance. Moving it onto the ledger
is required before real money moves, and is a behaviour change to flag to the product owner.

## 10. KasihKirim revenue

`internal.commission_rules` supports `party` (platform/agent/carrier), `basis`
(order_total/goods_subtotal/delivery_fee/flat), `rate_bps`, `flat_sen`, min/max caps, optional
`kirim_type` scoping and effective dating. `fn_quote_kirim` selects the current `platform` rule.

Seller commission is separate and already live: `sellers.commission_bps` falling back to
`ref.app_config.default_seller_commission_bps` (currently `1000` = 10%), applied by `rpc_checkout`
and stored on `orders.commission_sen`.

**Known trap, already documented in `0020`:** `fn_quote_kirim`'s commission lookup has **no context
filter** beyond `party='platform'`. Inserting a new `platform`/`goods_subtotal` rule to serve the
marketplace would silently change Kirim delivery pricing. Any marketplace commission rule must be
scoped (e.g. by `kirim_type = 'PASARAN'`) or held in a separate mechanism.

## 11. Dispute flow

`public.disputes` exists with `holds_escrow`, `refund_sen`, `resolution_note`, `resolved_by/at`,
`sla_due_at` and a category check. `fn_settle_delivery` refuses to settle while an unresolved
dispute holds escrow. `rpc_admin_resolve_dispute` (`0023`) records the decision and clears the hold.

**Gap:** there is **no way for a customer to raise one.** `disputes` has only a SELECT policy and
only a SELECT grant — no INSERT path, no RPC. "Laporkan Masalah" has no backend contract.

## 12. Refund flow

`internal.fn_refund` exists, and `ledger_transactions.reverses_id` supports reversal linkage.
Not yet audited line-by-line and not wired to any order path. Refunds must remain ledger-authoritative
reversals, never balance mutations.

## 13. COD interaction

Must stay distinct from prepaid. Already present: `internal.cod_collections`
(`UNIQUE(delivery_id)`), `carriers.cod_held_sen`, `float_limit_sen`, `default_float_limit_sen`,
COD-specific payment statuses, `fn_record_cod_collection`, `fn_remit_cod`, and a
`cod_handling_sen` surcharge inside `fn_quote_kirim`.

`ref.feature_gates` currently has `prepaid_payments_enabled = false` ("Blocked by MJ-01") and
`ref.app_config.payment_methods_enabled = ["COD"]`. Prepaid and COD orders must be distinguishable
end to end; a single order must not mix both.

## 14. Idempotency

Already strong: `internal.idempotency_keys` (with request hash and stored response),
`rpc_idem_lookup` / `rpc_idem_store` / `rpc_consume_nonce` (all service-role only), unique
`payments.idempotency_key`, unique `ledger_transactions.idempotency_key`, unique
`webhook_events (provider, provider_event_id)`, and `ON CONFLICT DO NOTHING` on the capture posting.

The settlement transaction key is `'settle:'||delivery_id`, so a repeated settlement cannot post
twice. Customer confirmation idempotency depends on the delivery state machine refusing a second
`CONFIRM_RECEIPT` from `COMPLETED`, which should be asserted by test rather than assumed.

## 15. RLS and security

Verified **live**, not assumed:

| Check | Result |
|---|---|
| `authenticated` has USAGE on schema `internal` | **false** |
| `anon` has USAGE on schema `internal` | **false** |
| `authenticated` can SELECT `internal.ledger_entries` | **false** |
| `authenticated` can SELECT `internal.payments` | **false** |
| PostgREST exposed schemas (`config.toml`) | `["public", "graphql_public"]` — `internal` not exposed |
| Service-role-only RPCs (`rpc_apply_payment_event`, `rpc_record_webhook`, `rpc_idem_*`, `rpc_consume_nonce`, `rpc_risk_signal`, `rpc_reconcile`) executable by `authenticated` | **no** |
| `public.orders` policies | 1 (SELECT only; no INSERT/UPDATE/DELETE policy) |
| `public.handover_codes` | `REVOKE ALL`, no SELECT policy at all |

So "Android cannot mutate the ledger" is **structural**, not merely policy: the schema is neither
exposed to PostgREST nor usable by the client roles. This is the correct posture and must be
preserved — every new financial table belongs in `internal`, and every client-facing money action
must be a `SECURITY DEFINER` RPC in `public` that validates the caller.

## 16. Risk controls

`internal.risk_signals` (subject, signal, severity 1-5, details) and service-role `rpc_risk_signal`
exist. Nothing consumes them. Settlement has no risk gate today; `delivery_transition_rules.guard_function`
is the intended hook and is unused.

## 17. Legal / compliance activation gate

`internal.fn_marketplace_gate` exists, alongside `ref.feature_gates`, `ref.app_config.payment_methods_enabled`
and `MUATAN-JUAL-COMPLIANCE.md`'s own §12 lifecycle. MJ-01 (escrow vs BNM) remains **open with
counsel** and blocks activation of prepaid money movement.

Per `MUATAN-JUAL-COMPLIANCE.md` §8 the questions still outstanding are: whether holding customer
funds pending delivery is a regulated payment/e-money activity under the Financial Services Act
2013; whether a licensed provider holding funds while KasihKirim only instructs the split discharges
that; whether Kirim BELI changes the analysis; trust-account/segregation requirements; and whether
COD-only avoids the issue.

**Build and test are permitted. Activation is not**, until: payment provider contracted, regulated
flow documented, custody mechanism agreed, refund/dispute/seller/carrier/customer terms published,
commission disclosed, KYC and payout requirements met, tax treatment settled, and the feature gate
plus `payment_methods_enabled` are deliberately flipped by a human.

## 18. Remaining implementation gaps

| # | Gap | Severity |
|---|---|---|
| G1 | Nothing creates `internal.payments`; no payment intent RPC | blocking |
| G2 | ~~No allocation model~~ — **FIXED (0024)**: `internal.payment_allocations` + order-aware capture split | done |
| G3 | ~~No `SELLER_PAYABLE` leg~~ — **FIXED (0024)** | done |
| G4 | ~~`fn_settle_delivery` refunds the buyer instead of paying the seller~~ — **FIXED (0024)**, see §22 | done |
| G5 | No order → delivery bridge; an order never becomes a carryable job | blocking |
| G6 | No seller fulfilment transitions (order stuck at `CREATED`) | blocking |
| G7 | No settlement eligibility predicate; conditions are implicit | high |
| G8 | `settlement_window_hours` configured but no scheduled `AUTO_SETTLE` sweep | high |
| G9 | No customer dispute-raise path ("Laporkan Masalah") | high |
| G10 | `rpc_my_earnings` not ledger-derived; ignores payouts | high |
| G11 | No seller wallet at all | high |
| G12 | No payment provider integration / webhook HTTP endpoint | blocking for activation |
| G13 | Stock not seller-manageable; no-inventory products sell unlimited | medium |
| G14 | `risk_signals` and `guard_function` unconsumed | medium |
| G15 | `fn_refund` not wired to any order path | medium |

---

## 19. Phased implementation plan

Each phase is one reviewable PR. No phase moves real money; activation is Phase N only.

| Phase | Scope | Gaps closed |
|---|---|---|
| **A** | *This audit.* No code. | — |
| **B** | Seller fulfilment transitions + stock management RPCs. Order leaves `CREATED`. | G6, G13 |
| **C** | `internal.payment_allocations` + `rpc_create_payment_intent` (sandbox provider only, clearly labelled). Allocation sum invariant enforced. | G1, G2 |
| **D** | Order-aware capture in `fn_apply_payment_event`: split into goods/delivery/commission holds. | G2 |
| **E** | Order → delivery bridge as a `PASARAN` kirim (`kirim_requests.order_id` and `ck_pasaran_has_order` already exist for this). | G5 |
| **F** | **Settlement engine**: `SELLER_PAYABLE` leg, explicit eligibility predicate, order-aware `fn_settle_delivery`, idempotency tests. | G3, G4, G7 |
| **G** | Auto-release sweep for `settlement_window_hours`; wire `guard_function` for dispute/risk holds. | G8, G14 |
| **H** | Ledger-derived seller wallet + carrier wallet correction (pending vs available, net of payouts). | G10, G11 |
| **I** | Customer dispute raise + refund paths wired to `fn_refund`. | G9, G15 |
| **J** | Android customer flow: product → checkout → protected payment → tracking → Terima Pesanan / Laporkan Masalah. | — |
| **K** | Android seller flow: products, stock, orders, pending/available wallet. | — |
| **L** | Android carrier flow: pending vs available earnings after settlement. | — |
| **M** | Admin/operations visibility: payments, allocations, settlements, refunds, risk holds, reconciliation. | — |
| **N** | Provider integration + legal/compliance activation gate. **Only here does real money move.** | G12 |

**Phase F is the one that must not be rushed** — it is where G4 lives, and where a mistake pays the
wrong party.

## 20. Test plan

Financial invariants asserted in pgTAP for every scenario:

- `payment.amount_sen = Σ allocations` at creation and after every event.
- Every `ledger_transaction` balances: `Σ DEBIT = Σ CREDIT`.
- Settlement never exceeds the held amount; refund never exceeds the refundable amount.
- No allocation negative unless explicitly supported.

Scenarios: payment created/authorized/held with correct allocations; carrier accept → pickup →
deliver → POD → confirm; settlement releases seller, carrier and commission exactly once;
**repeat settlement, repeat webhook, repeat confirmation, repeat payment event all no-op**;
dispute blocks settlement and each resolution produces the correct financial outcome; payment/seller/
carrier/delivery failure paths refund correctly.

Security scenarios, each asserted as *denied*: customer reading another customer's order or payment;
seller reading another seller's products or payables; carrier reading another carrier's earnings;
any client writing `internal.*`; any client altering an allocation amount or self-granting a role.

---

## 21. What was already changed before this instruction

For completeness, and because it is already live:

- Migration `0023_admin_review_surface.sql` — applied to the live database and pushed. Adds
  `rpc_admin_set_seller_status` and `rpc_admin_resolve_dispute`, plus `sellers.review_note`.
  Non-financial; it records dispute decisions and explicitly posts nothing to the ledger.
- The Android admin review queues, and a carrier navigation fix, pushed on the same branch.
- One live data change: the product "Ikan Pari" was moved `draft → active` at the owner's request.

No COD bridge or settlement change was written; that work stopped at research when this instruction
arrived.

---

## 22. Corrected settlement architecture (0024) — defect FIXED

### 22.1 Root cause

`internal.fn_settle_delivery` had exactly one commercial model in it: Kirim. It reached the goods
value through `internal.quotes.goods_budget_sen` and reconciled it against
`kirim_requests.actual_goods_sen` — the BELI field meaning *what the carrier actually spent buying
the goods on the requester's behalf*. A marketplace order never sets that field, because nobody goes
shopping: the buyer paid the seller's listed price at checkout.

So for an order-linked delivery:

```
v_actual := COALESCE(k.actual_goods_sen, 0)   -- NULL for an order  → 0
v_refund := q.goods_budget_sen - v_actual     -- → the entire goods value
...
fn_post(v_txn, 'REQUESTER_REFUND:'||k.requester_id, 'CREDIT', v_refund)
```

The buyer kept the goods and was credited their full value. The seller was credited nothing, because
no `SELLER_PAYABLE` leg existed anywhere in the codebase.

A second, quieter failure existed on today's data: `fn_quote_kirim` zeroes goods for any type other
than BELI, so a PASARAN quote carries `goods_budget_sen = 0`, the `IF q.goods_budget_sen > 0` goods
leg is skipped, and the money simply never leaves escrow. Which of the two fires depends only on
whether goods value was priced into the quote. **Either way the seller is never paid.**

### 22.2 Kirim vs marketplace — an explicit branch

Settlement now branches on `kirim_requests.kirim_type = 'PASARAN'`, the actual transaction type.
This is deliberately *not* an `actual_goods IS NULL` heuristic: the schema's own
`ck_pasaran_has_order` constraint already guarantees a PASARAN kirim carries `order_id`, so the
discriminator is structural.

| | Kirim (BELI / HANTAR) | Marketplace (PASARAN) |
|---|---|---|
| Goods money | budget reconciled against actual spend, remainder refunded | seller's price, owed to the seller |
| Source of truth | `quotes.goods_budget_sen` − `kirim_requests.actual_goods_sen` | `internal.payment_allocations` |
| Refund on settle | yes, unspent budget | **never** — every sen is already owed to a named party |
| Behaviour after 0024 | **byte-for-byte unchanged** | new |

### 22.3 Allocation model

`internal.payment_allocations` records declared settlement intent. **The ledger remains
authoritative for balances**; this table answers *who was owed what, and when was it released*.

```
SELLER   = order.goods_subtotal_sen - order.commission_sen
CARRIER  = quote.delivery_fee_sen - quote.commission_sen - delivery.agent_fee_sen
AGENT    = delivery.agent_fee_sen
PLATFORM = order.commission_sen + quote.commission_sen
```

Every amount comes from server-side rows written by `rpc_checkout` and `fn_quote_kirim`. Nothing is
client-supplied. Enforced invariants, each covered by a test:

- `Σ allocations = payment.amount_sen` — else `ALLOCATION_SUM_MISMATCH`
- no negative part — else `ALLOCATION_NEGATIVE`
- one row per party per payment — `ux_allocation_once`
- the delivery must belong to the payment's own order — else `ALLOCATION_ORDER_MISMATCH`
- `PLATFORM` has no payee; every other type must name one — `ck_allocation_payee`
- a discount is refused (`ALLOCATION_DISCOUNT_UNSUPPORTED`) until who funds it is decided — see §22.8

### 22.4 Ledger interaction

Worked example, customer pays RM130:

```
Capture   DEBIT  GATEWAY_CLEARING        13000
          CREDIT ESCROW_HELD_GOODS       10000     ← fn_split_order_capture
          CREDIT ESCROW_HELD_DELIVERY     3000

Settle    DEBIT  ESCROW_HELD_GOODS       10000
          DEBIT  ESCROW_HELD_DELIVERY     3000
          CREDIT SELLER_PAYABLE:<seller> 10000     ← the new leg
          CREDIT CARRIER_PAYABLE:<carrier> 2000
          CREDIT PLATFORM_COMMISSION      1000
```

Capture had to be corrected too: `fn_apply_payment_event` credited an order's entire amount to
`ESCROW_HELD_DELIVERY`, so a settlement debiting `ESCROW_HELD_GOODS` would have drained an account
that was never funded. Kirim and topup capture are untouched — the added branch is `ELSIF
pay.reference_type = 'order'`.

### 22.5 Settlement eligibility

`internal.fn_settlement_blocked_reason(delivery)` returns `NULL` when settlement may proceed, or the
reason it may not: `DELIVERY_NOT_FOUND`, `ALREADY_SETTLED`, `ESCROW_HELD_BY_DISPUTE`,
`PROOF_MISSING`, `PAYMENT_MISSING`, `PAYMENT_NOT_HELD`, `ALLOCATION_MISSING`,
`ALLOCATION_SUM_MISMATCH`, `ALLOCATION_NOT_HELD`.

Split out from settlement so an auto-release sweep can ask the same question without attempting a
write. `ALREADY_SETTLED` and the dispute hold apply to every delivery; the POD, payment and
allocation conditions are **marketplace-only by design** — for Kirim, POD is already enforced where
it belongs, on the `OUT_FOR_DELIVERY → DELIVERED` transition (0014), and re-checking it at
settlement would change Kirim behaviour this migration guarantees it does not touch.

### 22.6 Idempotency

Unchanged mechanism, hardened: the settlement transaction still keys on `settle:<delivery_id>`
(UNIQUE), but the insert is now `ON CONFLICT DO NOTHING` and returns early when it loses the race,
so a repeat settle is a **no-op rather than an exception**. Three consecutive settlements credit the
seller exactly once — asserted directly.

### 22.7 Refunds and disputes

Refunds stay separate from successful settlement and remain ledger reversals via the existing
`internal.fn_refund` and `ledger_transactions.reverses_id`; nothing here mutates a balance. An
unresolved dispute holding escrow still blocks settlement, now reported explicitly as
`ESCROW_HELD_BY_DISPUTE` rather than raised from inside the posting logic.

**Still missing (documented, not implemented here):** a customer path to *raise* a dispute.
`public.disputes` has a SELECT policy and a SELECT grant only — no INSERT path and no RPC — so
"Laporkan Masalah" has no backend contract yet. Tracked as G9.

### 22.8 Open commercial decision

Who funds an order discount — platform, seller, or campaign budget — has not been decided.
`fn_allocate_order_payment` refuses any order with `discount_sen <> 0` rather than silently charging
it to whichever party the arithmetic lands on. This must be answered before vouchers can apply to a
marketplace order.

### 22.9 Verification

Run on a fresh database (all 25 migrations from `0000`, then seed, then helpers):

| | Files | Assertions | Result |
|---|---|---|---|
| Baseline, before 0024 | 16 | 199 | PASS |
| After 0024 + new tests | **17** | **239** | **PASS** |
| New file against the *original* buggy function | 1 | 40 | **FAIL — 9 assertions**, as intended |

No existing assertion was weakened, changed or removed.

---

# 23. P1 — Marketplace transaction lifecycle (0025–0029)

Section 22 fixed how a marketplace order settles. It could not fix that no marketplace order
could ever *reach* settlement: nothing created the delivery job, nothing collected the money,
nothing declared the allocation, and nothing let a customer object. P1 closes that, backend only.
Real payment activation stays off.

## 23.1 Status of every part

**IMPLEMENTED AND TESTED**

| Capability | Where |
|---|---|
| Every product has a stock row; a product with no stock cannot be sold | `0025` |
| Seller sets and adjusts stock; movements are logged append-only | `0025` |
| Reservation → sale on pickup, reservation → shelf on cancel | `0025`, `0027` |
| Checkout prices the carriage leg through the existing quote engine | `0026` |
| Checkout opens a payment intent on the existing payments table | `0026` |
| Order → delivery bridge (`PASARAN` kirim carrying `order_id`) | `0027` |
| Carrier assignment declares the four-way allocation | `0027` |
| Seller→carrier handover codes, issue and verify | `0028` |
| COD capture at the doorstep, split into the two escrow accounts | `0027` |
| Customer confirmation, ownership-checked | `0027` |
| Customer-raised disputes that freeze settlement | `0028` |
| Risk holds that freeze settlement | `0029` |
| 48-hour auto-release sweep, resilient to ineligible rows | `0029` |
| Ledger-derived earnings for sellers and carriers | `0029` |
| Full refund as a linked ledger reversal | `0029` |

**SANDBOX / TEST ONLY**

- The prepaid authorisation path. `internal.payments` supports it and
  `fn_apply_payment_event` already handles an order capture, but no provider is
  connected and no webhook is wired to a real gateway.
- `internal.fn_sweep_settlements` is written and tested, and `seed.sql`'s cron entry now
  points at it, but scheduling only takes effect where `pg_cron` is present. Nothing in
  these migrations enables it in production.

**NOT ACTIVATED**

- `ref.feature_gates.prepaid_payments_enabled` remains `false` (MJ-01).
- `ref.app_config.payment_methods_enabled` remains `["COD"]`.
- Marketplace discounts and vouchers remain refused (§23.8).
- Partial refunds remain refused (§23.7).
- No Android marketplace UI. Every RPC below is backend surface only.

## 23.2 The lifecycle

```
seller sets stock
      ↓
customer checks out            rpc_checkout
  ├─ price snapshotted onto order_items
  ├─ stock reserved atomically
  ├─ delivery leg priced        fn_quote_order_delivery
  ├─ payment intent opened      fn_create_order_payment_intent   → order PENDING_PAYMENT
  └─ delivery job created       fn_bridge_order_to_delivery      → PASARAN kirim, POSTED
      ↓
carrier accepts                rpc_accept_offer                  → delivery MATCHED
  └─ allocation declared        fn_allocate_order_payment         (HELD, no money moves)
      ↓
seller hands over              rpc_issue_handover_code / rpc_verify_handover_code
      ↓
CONFIRM_PICKUP (proof)         → PICKED_UP    reservation becomes a sale
DEPART / START_DELIVERY        → IN_TRANSIT / OUT_FOR_DELIVERY
CONFIRM_DELIVERY (proof)       → DELIVERED    COD captured, escrow funded, order FULFILLED
      ↓
CONFIRM_RECEIPT  ──or──  48h   fn_sweep_settlements
      ↓
settlement                     fn_settle_delivery                → order SETTLED
  ├─ SELLER_PAYABLE
  ├─ CARRIER_PAYABLE
  └─ PLATFORM_COMMISSION
```

No new delivery status was added. There is still no `ACCEPTED`.

## 23.3 Order ↔ payment

One order, one payment intent, on `internal.payments` with `reference_type = 'order'`. There is
no second payment table and no second state machine. `ref.payment_status` is unchanged: the
conceptual states map onto values that already exist — `COD_PENDING` for an opened intent,
`CAPTURED` once money is in hand, `SETTLED` once released, `REFUNDED` once reversed. Reopening
an intent for an order that already has one returns the existing row rather than creating a
second claim.

## 23.4 Order ↔ delivery

`public.kirim_requests.order_id` and `ck_pasaran_has_order` have existed since `0001`;
`fn_bridge_order_to_delivery` is the first thing to use them. The delivery job's weight, volume,
category, handling flags and corridor are read back from the quote's `input_snapshot` — the same
snapshot that was priced — so the job that gets carried can never differ from the job that was
charged for. `deliveries` remains the single authority on delivery state; `orders.status` is a
projection driven from it, never the reverse.

The bridge runs at intent time, not at capture time, and that ordering is forced rather than
chosen: the allocation needs a delivery (for the carrier and agent legs), and the capture needs
the allocation (to split the goods and carriage escrow). So delivery → allocation → capture.

## 23.5 Stock

`public.inventory` is authoritative. A reservation is taken by a single conditional statement —
the predicate and the write are the same `UPDATE`, so two buyers racing for the last unit cannot
both win. `ck_inventory_not_oversold` remains the database-level backstop, never the mechanism.
`internal.fn_adjust_inventory` is the only writer of `on_hand`, and refuses any change that would
strand a live reservation.

The pre-P1 hole: `rpc_checkout` raised `INSUFFICIENT_STOCK` only when an inventory row existed,
so a product with no row sold without limit. `0025` guarantees the row for every product, past
and future, and `0026` removes the escape.

## 23.6 Settlement eligibility

`internal.fn_settlement_blocked_reason` returns `NULL` or the reason. Global to both product
lines: `ALREADY_SETTLED`, `ESCROW_HELD_BY_DISPUTE`, `RISK_HOLD`. Marketplace-only, deliberately:
`PROOF_MISSING`, `PAYMENT_MISSING`, `PAYMENT_NOT_HELD`, `ALLOCATION_MISSING`,
`ALLOCATION_SUM_MISMATCH`, `ALLOCATION_NOT_HELD`. Kirim settlement is byte-identical to what it
was before `0024`.

The sweep asks this question before attempting anything, and wraps each settlement in its own
exception block. Under the previous cron statement — a bare `SELECT fn_settle_delivery(id) FROM
deliveries WHERE …` — one ineligible marketplace order would have aborted the whole statement and
silently stalled settlement for every other delivery, every ten minutes.

## 23.7 Refunds

`internal.fn_refund_order` reverses the capture entry for entry and links the two transactions
through `ledger_transactions.reverses_id`. The pair sums to nothing on every account it touched.
A refunded payment then reads `PAYMENT_NOT_HELD`, so the same money cannot also be settled out to
the seller and carrier.

Partial refunds are refused. A partial refund is not a reversal; it is a renegotiation of a
four-way split, and which party gives up which sen is a commercial decision nobody has made.
Refunding after settlement is refused for the same reason: the money is already credited, and
clawing it back is a payout adjustment, not a payment reversal.

`internal.fn_refund` (Kirim, `0004`) is untouched.

## 23.8 Discount funding — still unresolved

Unchanged from §22.8, and now enforced one step earlier. `rpc_checkout` refuses a marketplace
checkout carrying a voucher code, `fn_bridge_order_to_delivery` refuses a discounted order, and
`fn_allocate_order_payment` refuses it at settlement. Previously the order was accepted and only
refused at settlement — money in, nothing out.

The question remains: **who funds a marketplace discount?** Seller-funded, platform-funded,
shared, or campaign-specific. Kirim vouchers are unaffected and keep working.

## 23.9 Security model

Every new function is `SECURITY DEFINER` with `SET search_path = ''`, revoked from `PUBLIC` and
`anon`, and granted to `authenticated` only where a signed-in user legitimately calls it. The
`internal` helpers get no grant at all: schema `internal` has no `USAGE` for `anon` or
`authenticated` (`0000`) and is absent from `config.toml`'s exposed schema list, so it is
unreachable through PostgREST regardless.

One pre-existing hole was found and closed. `rpc_delivery_transition` checked that the caller
*held* a role the transition permits, and stopped there. Holding the `customer` role is not the
same as being *this* delivery's customer: any signed-in customer could `CONFIRM_RECEIPT` a
stranger's delivery and release a stranger's escrow. The RPC now also checks that the caller is
the party they claim to be — requester for `customer`, the assigned carrier for `carrier`, the
order's seller for `seller`. Agent and admin roles stay unrestricted, which is what those roles
are for.

Handover codes are stored only as a SHA-256 of `delivery:leg:code`, so a digest is useless on any
other delivery. The table has no SELECT policy and no grant, so it is readable by nobody. A wrong
code returns a result rather than raising, because a raise would roll back the attempt counter
and make the five-attempt lockout unreachable.

## 23.10 Verification

Fresh database, all migrations from `0000`, then seed, then helpers:

| | Files | Assertions | Result |
|---|---|---|---|
| Baseline (through `0024`) | 17 | 239 | PASS |
| New P1 coverage (`16`–`21`) | 6 | 169 | PASS |
| **Total** | **23** | **408** | **PASS** |

Four assertions in `14_checkout_and_growth.test.sql` were rewritten, none weakened. They asserted
behaviour P1 deliberately changes: that `total_sen` equals the goods subtotal (it now includes the
delivery fee), that a product without an inventory row is not stock-tracked (every product now is),
and that a voucher discount is applied to a marketplace order (it is now refused). Each was
replaced by an assertion of the new, stricter behaviour.
