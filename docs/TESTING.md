# KasihKirim — Test Strategy

Verifies the invariants declared in [`PRD.md`](./PRD.md) §8, the state machines in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §5, and the controls in [`SECURITY.md`](./SECURITY.md).

---

## 1. What we are actually testing for

Standard coverage metrics are close to worthless for this product. A system can have 90 % line coverage and still let two carriers accept the last slot on a truck, or let a rounding error accrete unspent grocery money into revenue.

The tests that matter here defend a small number of properties that are **unrecoverable in the physical world** when they fail:

| Property | Failure looks like | Priority |
|---|---|---|
| Capacity is never oversold | A parcel that physically does not fit, in a village, with no second vehicle for three days | **Critical** |
| Money always balances | Silent divergence that compounds until someone notices in month four | **Critical** |
| Unspent budget always returns | Slow theft from the poorest users on the platform | **Critical** |
| Delivery state is server-owned | A carrier marking themselves paid | **Critical** |
| Handovers cannot be replayed | Double payout on one delivery | **Critical** |
| Offline work never duplicates | Two ledger postings from one confirmed delivery | **Critical** |
| RLS denies what it should | One user reading another's KYC | **Critical** |
| Payloads stay small | Users burning prepaid credit | High |
| The app runs on a 2 GB phone | The target market cannot use the product | High |

Everything below exists to defend that list. Coverage percentages are a secondary signal.

---

## 2. Test pyramid

```
                    ┌──────────────────┐
                    │  Field pilot     │   Real carriers, real Beluran corridor
                    │  (§12)           │   Unautomatable, non-negotiable
                    ├──────────────────┤
                    │  E2E — Maestro   │   ~40 flows, real device matrix
                    ├──────────────────┤
                    │  Integration     │   ~250 — Supabase local, real Postgres
                    │  + pgTAP         │   RLS matrix, constraints, functions
                    ├──────────────────┤
                    │  Unit            │   ~800 — pure logic, no I/O
                    └──────────────────┘
```

Deliberately integration-heavy. Most of this system's correctness lives in Postgres constraints, triggers and policies — testing it with mocks would test the mocks.

| Layer | Tool | Runs |
|---|---|---|
| Unit (TS) | Vitest | Every commit |
| Database | **pgTAP** | Every commit |
| Edge Functions | `deno test` | Every commit |
| Integration | Vitest + Supabase CLI local stack | Every PR |
| Contract (gateway) | Recorded fixtures | Every PR |
| E2E mobile | **Maestro** | Nightly + pre-release |
| Load | k6 | Weekly + pre-release |
| Device performance | Firebase Test Lab | Pre-release |
| Security | Semgrep, `npm audit`, gitleaks | Every commit |

**Maestro over Detox:** YAML flows, no native build step for the test runner, runs against EAS-built APKs directly, and tolerates the slow, flaky UI timings of a low-end device far better.

---

## 3. CI gates

A pull request cannot merge unless all of these pass.

| Gate | Threshold |
|---|---|
| Type check | Zero errors, `strict` |
| Lint | Zero errors |
| Unit coverage — money and state modules | **95 %** |
| Unit coverage — overall | 80 % |
| pgTAP | 100 % pass |
| **RLS matrix** | Every table × role × operation asserted, allow **and** deny |
| **Every new table has policies + tests** | Enforced by a schema-diff check |
| **`(SELECT auth.uid())` lint** | No bare `auth.uid()` in any policy |
| Payload budgets | No endpoint over its `API.md` §6 budget |
| APK size | ≤ 25 MB per-ABI download |
| Secret scan | Clean |
| Dependency audit | No critical/high advisories |
| Migration replay | Reproducible from zero |

---

## 4. Database tests (pgTAP)

### 4.1 The RLS matrix

The single most important test suite in the repository. It is generated from the write-access matrix in `DATABASE.md` §14, so the matrix and the tests cannot drift.

For each table × each role × each of SELECT/INSERT/UPDATE/DELETE, assert the expected outcome — **including every denial**.

```sql
BEGIN;
SELECT plan(12);

-- A carrier browsing the board sees the request but not contact details.
SELECT tests.authenticate_as('carrier_rahman');
SELECT is(
  (SELECT count(*) FROM public.kirim_requests WHERE status = 'POSTED'), 3::bigint,
  'carrier sees posted board items');

-- ...but cannot see another user's draft.
SELECT is(
  (SELECT count(*) FROM public.kirim_requests WHERE status = 'DRAFT'), 0::bigint,
  'carrier cannot see other users drafts');

-- Deliveries are server-owned: no write path exists at all. (BR-904)
SELECT throws_ok(
  $$ UPDATE public.deliveries SET status = 'DELIVERED' WHERE id = tests.fixture('delivery_1') $$,
  '42501', NULL, 'carrier cannot update delivery status directly');

-- Handover codes are never readable by anyone.
SELECT is(
  (SELECT count(*) FROM public.handover_codes), 0::bigint,
  'handover codes invisible to carrier');

-- internal schema is unreachable.
SELECT throws_ok(
  $$ SELECT * FROM internal.ledger_entries $$,
  '42501', NULL, 'ledger unreachable from an authenticated JWT');

SELECT tests.authenticate_as('customer_aisyah');
SELECT is(
  (SELECT count(*) FROM public.profiles WHERE id <> tests.uid('customer_aisyah')), 0::bigint,
  'customer cannot enumerate other profiles');

SELECT * FROM finish();
ROLLBACK;
```

**Deny cases are the point.** A suite that only asserts what users *can* do will pass happily against a policy that grants everything.

### 4.2 Constraint tests

Each of these asserts that the *database* refuses, not that application code declines.

```sql
-- Overbooking is structurally impossible (BR-903)
SELECT throws_ok(
  $$ UPDATE public.trips SET reserved_weight_grams = capacity_weight_grams + 1
     WHERE id = tests.fixture('trip_beluran_kk') $$,
  '23514', NULL, 'ck_trip_weight_capacity blocks overbooking');

-- Carrier float covers COD + procurement advance together (BR-908)
SELECT throws_ok(
  $$ UPDATE public.carriers
     SET cod_held_sen = 40000, procurement_advance_sen = 20000
     WHERE id = tests.fixture('carrier_1') $$,          -- limit is 50000
  '23514', NULL, 'ck_carrier_exposure blocks combined float breach');

-- Budget cap cannot be exceeded without an approved variance (BR-913)
SELECT throws_ok(
  $$ UPDATE public.kirim_requests SET actual_goods_sen = 4200
     WHERE id = tests.fixture('kirim_beli_cap_3500') $$,
  'check_violation', NULL, 'budget cap enforced without variance');

-- ...and CAN be exceeded with one.
SELECT lives_ok(
  $$ SELECT tests.approve_variance('kirim_beli_cap_3500', 4200);
     UPDATE public.kirim_requests SET actual_goods_sen = 4200
     WHERE id = tests.fixture('kirim_beli_cap_3500') $$,
  'approved variance permits the overspend');

-- Ledger must balance (deferred constraint fires at COMMIT)
SELECT throws_ok(
  $$ BEGIN;
     SELECT tests.post_unbalanced_transaction();
     COMMIT $$,
  'check_violation', NULL, 'unbalanced ledger transaction cannot commit');

-- RM250 platform ceiling on budget cap (C-03)
SELECT throws_ok(
  $$ INSERT INTO public.kirim_requests (..., budget_cap_sen) VALUES (..., 25001) $$,
  '23514', NULL, 'budget cap ceiling enforced');

-- No self-dealing (BR-910)
SELECT throws_ok(
  $$ INSERT INTO public.reviews (rater_id, ratee_id, ...) VALUES (u, u, ...) $$,
  '23514', NULL, 'ck_no_self_review');
```

### 4.3 State machine — exhaustive

Generated from `ref.delivery_transition_rules`, so the test set expands automatically when a rule is added.

```sql
-- Every (from_status × event) NOT in the rules table must be rejected.
DO $$
DECLARE s ref.kirim_status; e text;
BEGIN
  FOREACH s IN ARRAY enum_range(NULL::ref.kirim_status) LOOP
    FOREACH e IN ARRAY tests.all_events() LOOP
      IF NOT EXISTS (SELECT 1 FROM ref.delivery_transition_rules
                     WHERE from_status = s AND event = e) THEN
        PERFORM throws_ok(
          format('SELECT internal.fn_delivery_transition(%L, %L, ...)', s, e),
          'STATE_INVALID_TRANSITION');
      END IF;
    END LOOP;
  END LOOP;
END $$;
```

Also asserted: every non-terminal state has at least one outgoing transition (no dead ends stranding a parcel), every terminal state has none, and every state is reachable from `DRAFT`.

---

## 5. Concurrency tests

These cannot be written as unit tests. They need real connections racing against real Postgres.

### 5.1 Overbooking

```ts
test('exactly capacity is consumed under N-way contention', async () => {
  const trip = await seedTrip({ capacityWeightGrams: 10_000, capacityParcels: 5 });
  const kirims = await seedKirims(20, { weightGrams: 2_000 });

  // 20 carriers race for 5 slots / 10 kg.
  const results = await Promise.allSettled(
    kirims.map(k => rpc('accept_offer', { trip_id: trip.id, kirim_id: k.id }))
  );

  const accepted = results.filter(r => r.status === 'fulfilled');
  expect(accepted).toHaveLength(5);

  const t = await fetchTrip(trip.id);
  expect(t.reserved_weight_grams).toBe(10_000);   // exactly, never more
  expect(t.reserved_parcels).toBe(5);

  const rejected = results.filter(r => r.status === 'rejected');
  expect(rejected.every(r => r.reason.code === 'CAPACITY_EXCEEDED')).toBe(true);
});
```

Run at concurrency 2, 5, 20 and 50. Any run producing `reserved > capacity` is a **release blocker**, not a bug ticket.

### 5.2 Webhook idempotency

```ts
test('same webhook delivered 10× concurrently produces one effect', async () => {
  const event = fixture('billplz.payment.paid');
  await Promise.all(Array(10).fill(0).map(() => postWebhook(event)));

  expect(await countLedgerTransactions(event.payment_id)).toBe(1);
  expect(await countWebhookEvents(event.id)).toBe(1);
  expect(await escrowBalance(event.payment_id)).toBe(5000);   // not 50000
});
```

### 5.3 Out-of-order webhooks

```ts
test('a stale webhook after settlement is ignored, not applied', async () => {
  await postWebhook(fixture('payment.paid'));
  await postWebhook(fixture('payment.pending'));   // arrives late

  const p = await fetchPayment(id);
  expect(p.status).toBe('SUCCEEDED');
  expect(await webhookStatus('payment.pending')).toBe('IGNORED_OUT_OF_ORDER');
});
```

### 5.4 Offline replay

```ts
test('an offline handover retried 11× produces one transition', async () => {
  const key = uuid();                                     // born at user action
  const payload = { delivery_id, event: 'CONFIRM_DELIVERY', proof: qrProof };

  for (let i = 0; i < 11; i++) {
    await rpc('delivery_transition', payload, { idempotencyKey: key });
  }

  expect(await countDeliveryEvents(delivery_id, 'CONFIRM_DELIVERY')).toBe(1);
  expect(await countLedgerTransactions(delivery_id)).toBe(1);
});
```

---

## 6. Money tests

Property-based, using `fast-check`. Money bugs hide in the cases nobody thought to write by hand.

### 6.1 Invariants

```ts
test.prop([arbitraryLedgerTransaction()])('every posting balances', async (txn) => {
  await postLedger(txn);
  const { debits, credits } = await sumEntries(txn.id);
  expect(debits).toBe(credits);
});

test.prop([arbitraryOrder()])('splits sum exactly to the total', async (order) => {
  const s = await settle(order);
  expect(s.carrierEarning + s.platformCommission + s.agentFee + s.sellerPayable)
    .toBe(order.totalSen);          // integer sen — no tolerance, no epsilon
});

// BR-915 — the one that protects the poorest users on the platform.
test.prop([arbitraryBeliKirim()])('unspent budget always returns', async (k) => {
  const s = await settleBeli(k);
  expect(s.goodsEscrowSen).toBe(s.actualCostSen + s.refundToRequesterSen);
  expect(s.refundToRequesterSen).toBeGreaterThanOrEqual(0);
  expect(s.platformKeptFromGoods).toBe(0);
});

// Confirmed commission: 25% of order total (deck slide 07).
test('commission is 25% of order total', async () => {
  const q = await quote({ goodsBudgetSen: 3500, deliveryFeeSen: 1500 });
  expect(q.orderTotalSen).toBe(5000);
  expect(q.commissionSen).toBe(1250);
});
```

### 6.2 Rounding

```ts
test.prop([fc.integer({ min: 1, max: 100_000 })])('no sen is created or lost', (total) => {
  const parts = splitCommission(total, 2500);      // 25%
  expect(parts.reduce((a, b) => a + b, 0)).toBe(total);
});
```

The remainder policy is fixed and tested: fractional sen accrue to the **platform**, never to a user, and never vanish. A total that does not reconstruct exactly is a failure.

### 6.3 Reconciliation

```ts
test('a full simulated day reconciles to zero', async () => {
  await simulateDay({ deliveries: 500, disputes: 12, refunds: 20,
                      codRemittances: 40, beliVariances: 30, vouchers: 60 });
  const r = await runReconciliation();
  expect(r.varianceSen).toBe(0);
  expect(r.unbalancedTransactions).toHaveLength(0);
});
```

---

## 7. Handover tests

| Test | Assertion |
|---|---|
| Valid QR | Transition succeeds, `proof_quality='STRONG'` |
| Tampered payload | `PROOF_INVALID_SIGNATURE` |
| Tampered signature | `PROOF_INVALID_SIGNATURE` |
| Replayed QR | Second attempt `PROOF_NONCE_CONSUMED`; risk signal raised |
| QR for a different delivery | Rejected |
| QR submitted by the wrong carrier | Rejected |
| Correct OTP | Succeeds |
| Wrong OTP × 5 | Locks; sixth attempt rejected even if correct |
| OTP after rotation | Old code fails, new code succeeds |
| Proof 300 m from node | `STRONG` |
| Proof 4 km from node | `STRONG`, flagged |
| Proof 40 km from node | `SUSPECT`, review queue, settlement delayed |
| Mock location flag | `SUSPECT` regardless of distance |
| Clock skew 6 h | Flagged; server time used for ordering |
| Photo-only proof | `WEAK`; extended settlement; review queue |
| **Offline QR scanned, submitted 3 days later** | **Succeeds** — expiry is bound to the leg, not wall-clock |

That last row is a real scenario on the Beluran corridor, and getting it wrong would strand parcels and earnings.

---

## 8. E2E flows (Maestro)

Run on the **floor device profile** (2 GB RAM, Android 7) and on a mid-range Android 14 device.

| # | Flow | Covers |
|---|---|---|
| E1 | Register → OTP → profile → join community | FR-100..104, 321 |
| E2 | Add address with GPS + landmark photo | FR-120..122 |
| E3 | **Create Kirim BELI, 4-step wizard, RM 50 budget** | FR-140, 150 — the deck's primary flow |
| E4 | Post to Papan Kirim → carrier sees it ranked | FR-160..163 |
| E5 | Carrier announces trip Beluran→KK with capacity | FR-242 |
| E6 | **One-tap announce return leg** | FR-243 — the Kirim Balik primitive |
| E7 | Carrier accepts → capacity reserved → codes issued | FR-246 |
| E8 | Carrier records purchase within budget + receipt | FR-154 |
| E9 | **Price variance: market price above cap → approve → top-up** | FR-152 |
| E10 | **Price variance: requester offline → timeout → no purchase** | FR-153 |
| E11 | QR pickup handover | FR-221 |
| E12 | QR delivery handover + recipient confirms receipt | FR-222, BR-907 |
| E13 | OTP fallback when recipient has no smartphone | FR-222 |
| E14 | COD collection and reconciliation | FR-251 |
| E15 | Carrier earnings → payout request | FR-249, 250 |
| E16 | Marketplace browse → cart → checkout → pay | FR-180..185 |
| E17 | Seller lists product with images | FR-272, 273 |
| E18 | Open dispute → evidence → resolution | FR-313..315 |
| E19 | Voucher applied at Kirim creation | FR-149, 189 |
| E20 | Badge awarded on first completed Kirim | FR-319 |
| E21 | **Full offline: flight mode → scan → photo → reconnect → sync** | NFR-140..142 |
| E22 | Force-upgrade gate | §4.15 |
| E23 | Account deletion request | FR-106 |

### 8.1 Offline E2E in detail

```yaml
# E21 — the flow that proves the product works in Beluran
- launchApp
- runFlow: login_as_carrier.yaml
- tapOn: "Trip Saya"
- assertVisible: "Beluran → Kota Kinabalu"
- tapOn: "Muat turun manifes"      # cache manifest to SQLite
- assertVisible: "Manifes disimpan"

- setAirplaneMode: true             # ── no signal from here ──

- tapOn: "Imbas QR"
- runFlow: scan_qr_fixture.yaml
- assertVisible: "Disimpan — menunggu talian"
- tapOn: "Ambil gambar bukti"
- runFlow: capture_photo.yaml
- assertVisible: "2 perkara menunggu talian"

- stopApp
- launchApp                          # survives app kill
- assertVisible: "2 perkara menunggu talian"

- setAirplaneMode: false             # ── signal returns ──
- extendedWaitUntil:
    visible: "Semua sudah dihantar"
    timeout: 60000

- runFlow: assert_server_state.yaml  # exactly one transition, one ledger posting
```

---

## 9. Performance tests

### 9.1 Device budgets (`PRD.md` §9.1)

| Metric | Budget | Tool |
|---|---|---|
| Cold start → interactive | ≤ 3.5 s | Maestro + `adb` trace |
| JS heap steady state | ≤ 180 MB | Android Studio profiler |
| 30-min soak | Zero OOM, no monotonic heap growth | Automated soak |
| Board scroll | ≥ 50 fps | Perfetto |
| APK download (per-ABI) | ≤ 25 MB | `bundletool get-size` |
| Installed size | ≤ 90 MB | Test Lab |
| Battery, 4 h active trip | ≤ 12 % | Battery Historian |

### 9.2 Network simulation

Every E2E flow runs under a throttled profile as well as unthrottled:

| Profile | Bandwidth | RTT | Loss |
|---|---|---|---|
| `rural-3g` | 400 kbps | 400 ms | 3 % |
| `rural-edge` | 120 kbps | 800 ms | 8 % |
| `flapping` | Alternates 4G ↔ none every 20 s | | |

`flapping` is the one that finds real bugs. It is where duplicate submissions, lost outbox items and stuck spinners surface.

### 9.3 Load (k6)

| Scenario | Target |
|---|---|
| Board queries | 200 rps, p95 < 400 ms |
| Quote generation | 50 rps, p95 < 300 ms |
| `accept_offer` on **one** trip | 50 concurrent, zero overbooking |
| Webhook burst | 500 in 10 s, all idempotent |
| Sync pull, 200 changes | p95 < 800 ms |
| Reconnection storm | 1 000 devices in 60 s (simulates a tower recovering) |

---

## 10. Localisation and accessibility

| Test | Assertion |
|---|---|
| BM is default | No English string appears in a fresh install's critical path |
| Coverage | Every user-facing key has a `ms` value; CI fails on a missing key |
| Overflow | Longest BM string renders without truncation at 200 % font scale |
| Error localisation | Server returns `message_ms`; client prefers it |
| TalkBack | Every interactive element labelled; E1–E15 completable with TalkBack only |
| Touch targets | ≥ 48 dp — automated layout assertion |
| Contrast | ≥ 4.5:1 against the brand palette (deep green / gold / orange on cream) |
| Critical numerics | COD amount, OTP and budget render at large size with high contrast |

Accessibility here is not compliance theatre. The users include older kampung residents reading a 6-digit code off a cracked screen in daylight.

---

## 11. Security testing

| Test | Method |
|---|---|
| RLS matrix | pgTAP, every table × role × operation |
| Privilege escalation | Forged JWT with injected `roles` claim — must fail signature |
| Price tampering | Submit a modified amount — must be ignored, risk signal raised |
| Quote replay | Reuse a consumed `quote_id` → `QUOTE_ALREADY_USED` |
| Webhook forgery | Invalid HMAC → 401, nothing processed |
| IDOR sweep | Enumerate UUIDs across every endpoint → 404, never 403-with-detail |
| KYC access | Non-compliance role → denied; compliance access → audit row written |
| SQL injection | Automated fuzz on every text input |
| Secret scan | gitleaks on every commit and on the built APK |
| Dependency audit | Every commit; critical fails the build |
| Penetration test | Third party, pre-launch and annually |

---

## 12. Field pilot

Some things cannot be tested in CI. The Beluran↔KK corridor is 250 km of mixed sealed and gravel road through areas with real coverage gaps, and no emulator reproduces that.

**Pilot design** (`PRD.md` §10, P1):

| Parameter | Value |
|---|---|
| Corridor | Beluran ↔ Kota Kinabalu, via Telupid |
| Carriers | 5–8 real carriers already making the journey |
| Requesters | 30–50 residents across Beluran and Kg Kepayan Baru |
| Duration | 6 weeks |
| Volume | ≥ 50 completed deliveries |
| Payment | COD only — prepaid deferred until LGL-02 resolves |

**Exit criteria — all must hold:**

- Zero overbooking incidents
- Zero money discrepancies; 42 consecutive clean daily reconciliations
- Zero budget-cap breaches without an approved variance
- ≥ 95 % of handovers closed with QR or OTP, not photo-only
- Zero unspent-budget retention events
- Crash-free sessions ≥ 99 %
- Median data per delivery ≤ 600 KB

**What the pilot is really measuring.** Automated tests prove the system is internally consistent. The pilot answers questions no test can: does a carrier actually stop to buy prawns at a market, does a recipient understand a 6-digit code read over a phone, does the QR scan in bright sun off a cracked screen, and — the commercially decisive one — **does trip fill rate reach a level that makes RM 2.50 per parcel worth a carrier's time**. That last question determines whether the business works, and it cannot be answered anywhere else.

Structured debrief with every carrier weekly. Instrument abandonment at each of the four Kirim wizard steps.

---

## 13. Test data

| Concern | Approach |
|---|---|
| Seed | Deterministic fixtures: Beluran corridor graph, 5 categories, 20 users across all roles, 3 trips, 15 Kirim spanning all three types |
| Isolation | Every test in a transaction, rolled back; no shared mutable state |
| Time | `pg_sleep` never used; clock injected via a mockable `internal.now()` |
| PII | Synthetic only. **Production data is never copied to any lower environment.** |
| Money | Amounts chosen to expose rounding: 333, 999, 1, 12_345 sen |
| Realism | Item descriptions from the deck: *"Udang galah saiz sederhana, 2kg, yang masih hidup kalau ada"* |

---

## 14. Release readiness checklist

- [ ] All CI gates green on the release commit
- [ ] RLS matrix complete — no table without allow **and** deny assertions
- [ ] Concurrency suite green at 50-way contention
- [ ] Money property tests green, including the `BELI` refund invariant
- [ ] 7 consecutive clean daily reconciliations in staging
- [ ] E2E green on floor device and mid-range device
- [ ] E21 offline flow green under `flapping`
- [ ] Payload budgets within limits
- [ ] APK ≤ 25 MB; cold start ≤ 3.5 s on the floor device
- [ ] BM localisation complete; no English in a critical path
- [ ] TalkBack pass on E1–E15
- [ ] Security checklist (`SECURITY.md` §13) complete
- [ ] Penetration test findings closed
- [ ] Play pre-launch report clean
- [ ] Rollback rehearsed: EAS Update revert and Play halt both executed in staging
- [ ] Runbooks current; on-call briefed
