# KasihKirim

*Kirim dengan kasih, dari kampung ke bandar.*

Android-only delivery, procurement and marketplace network for **Sabah**.

**Product scope: Sabah-wide** — all 27 districts represented from day one,
activation driven by configuration.
**Initial pilot: Beluran / Paitan / Kota Kinabalu.**

---

## What is here

```
docs/          8 architecture documents — read PRD.md first
prototype/     kasihkirim.html — runnable click-through, no install needed
supabase/      migrations, seed, config
apps/mobile/   Expo scaffold (Android only)
```

## 0. After cloning — restore executable bits

Git archives and file transfers do not always preserve the executable bit.
Run once after cloning:

```bash
chmod +x scripts/*.sh .devcontainer/setup.sh
git update-index --chmod=+x scripts/*.sh .devcontainer/setup.sh
```

Verify file integrity against the shipped manifest:

```bash
sha256sum -c MANIFEST.sha256
```

## 1. Try the prototype (zero setup)

Open `prototype/kasihkirim.html` in any browser.

Toggle **👤 Pelanggan / 🚚 Pembawa** to switch roles, **📶** to cut the signal.

It implements the real invariants, not a mockup:

- 25 % platform commission of order total
- RM 250 budget cap, blocked at the point of purchase
- Capacity guard — a full trip refuses cargo
- Unspent budget refunded in full at settlement
- Offline outbox with exactly-once replay

**Demo path:** Buat Kirim Baru → 2 kg seafood, RM 35 budget → post →
switch to Pembawa → Papan → accept → Rekod Pembelian.
Enter **RM 42** (over budget) and it forces the variance flow.
Enter **RM 28** and it settles with RM 7 returned.

## 2. Run the backend

```bash
npm i -g supabase
supabase start
supabase db reset          # applies 0000-0004 + seed from an empty database
supabase test db           # pgTAP: constraints, RLS matrix, state machine, money
supabase status            # copy the anon key
```

`supabase test db` is the important one. The SQL in this repo has **never been
executed** — it was written statically. The tests are what will surface both my
mistakes and any real invariant breach. Run them before trusting anything.

Verify the corridor seeded correctly:

```sql
SELECT distance_km FROM ref.node_distance_matrix m
  JOIN ref.route_nodes a ON a.id=m.from_node_id
  JOIN ref.route_nodes b ON b.id=m.to_node_id
 WHERE a.name='Beluran' AND b.name='Kota Kinabalu';
-- expect ~266 km  =>  pricing band 'long_haul'
```

Verify the money rule:

```sql
SELECT total_sen, commission_sen FROM internal.fn_quote_kirim(
  'BELI',
  (SELECT id FROM ref.categories WHERE slug='hasil-laut'),
  2000, 8000, 3500,
  (SELECT id FROM ref.route_nodes WHERE name='Beluran'),
  (SELECT id FROM ref.route_nodes WHERE name='Kg Kepayan Baru'),
  '{PERISHABLE,COLD_CHAIN}', 'COD',
  '00000000-0000-0000-0000-000000000001');
-- commission should be 25% of total
```

## 3. Deploy the Edge Functions

```bash
supabase functions deploy quote-kirim delivery-transition handover-verify
supabase functions deploy payment-webhook --no-verify-jwt   # HMAC auth, not JWT

supabase secrets set OTP_PEPPER=$(openssl rand -hex 32)
supabase secrets set PAYMENT_WEBHOOK_SECRET=<from provider>
supabase secrets set QR_PUBLIC_KEY=<base64 ed25519 public key>
```

## 4. Run the app

```bash
cd apps/mobile
npm install
cp .env.example .env        # paste the anon key from `supabase status`
npx expo start
```

Android only. There are no iOS targets and adding one is out of scope.

Screens that exist today: splash, phone, OTP, customer home, and step 1 of the
Kirim wizard wired to the live `quote-kirim` function. Everything else — the
board, carrier manifest, handover, settlement — exists in the prototype and in
the docs, but not yet as app screens.

---

## Migration order matters

Apply in strict order: `0000 → 0001 → 0002 → 0003 → seed`.

`0000_prelude.sql` exists for one reason: Postgres resolves functions used in
RLS policies **at policy-creation time**, so every `auth.*` helper must exist
before any migration creates a policy that calls one. Defining them later means
`db reset` fails partway through `0002`.

Two FKs are added by `ALTER` after their targets exist —
`profiles.home_community_id` and `addresses.agent_hub_id` — because inlining
them creates a cycle that will not apply from zero.

The `custom_access_token_hook` grants in `0003` are load-bearing. Without them
the hook runs but returns nothing, so every policy reading a role claim silently
denies and a logged-in user sees an empty app **with no error**.

## Non-negotiables

| Rule | Where it is enforced |
|---|---|
| Money is computed server-side | `internal.fn_quote_kirim` — no coefficients ship to the client |
| Money is integer `sen` | No float anywhere in the money path |
| No overbooking | Row lock + `CHECK` constraint + TTL holds |
| Delivery state is server-owned | No `UPDATE` policy or grant on `deliveries` |
| Budget cap cannot be exceeded | Trigger requires an approved variance |
| Unspent budget always returns | Settlement invariant `escrow = actual + refund` |
| Ledger always balances | Deferred constraint trigger at COMMIT |
| Webhooks are idempotent | `UNIQUE (provider, provider_event_id)` |

## Open blockers

1. **LGL-02** — the deck markets platform-held escrow. That may be a regulated
   activity under Bank Negara. Blocks prepaid payments; a COD-only pilot can
   proceed without it. **Needs a lawyer.**
2. Who funds the carrier's purchase float in `BELI`?
3. Cargo liability cap.
4. `CLAUDE.md` was never supplied — conventions here are proposed, not inherited.
