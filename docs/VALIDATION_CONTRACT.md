# Validation Contract — Kotlin, Zod and the Database

Written before Phase 3 builds Kirim submission. Every claim below was read from
the repository at `a9eacbc`.

---

## 1. The audit assumption was wrong

`apps/mobile/src/features/kirim/schema.ts` carries this comment:

> *"Shared with the Edge Function. One definition, validated on both sides:
> client-side is UX, server-side is the control."*

**It is not shared.** The evidence:

```
$ grep -rl 'zod' supabase/            →  0 files
$ ls supabase/functions/_shared/      →  clients.ts  http.ts  idempotency.ts
```

`supabase/functions/quote-kirim/index.ts` does exactly this:

```ts
const b = await req.json();
const { data, error } = await userClient(req).rpc('rpc_quote_kirim', { ... });
if (error) return fromPgError(error.message, requestId);
```

It parses JSON, forwards the fields to the RPC, and maps the Postgres error. It
**does not validate**. The Zod schema exists on the client only; the comment
describes an intention that was never implemented.

This changes the problem. There is no shared-definition property to preserve in
the move to Kotlin — **there is nothing to lose.**

---

## 2. Where validation is actually enforced

Three layers exist today, and only the third is authoritative.

### Layer 1 — Zod, client-side, Expo only

10 field rules plus one cross-field refinement (`BELI` requires a budget).
Purely UX. Deleting it would weaken nothing but the user experience.

### Layer 2 — Edge Functions

**None.** Pass-through with error mapping.

### Layer 3 — PostgreSQL, authoritative

`0001_schema.sql` enforces every rule the Zod schema claims, as constraints:

| Rule | Zod | Database |
|---|---|---|
| description 3–500 chars | `.min(3).max(500)` | `CHECK (length(item_description) BETWEEN 3 AND 500)` — line 522 |
| weight 100–500 000 g | `.min(100).max(500_000)` | `CHECK (est_weight_grams BETWEEN 100 AND 500000)` — line 524 |
| budget positive | `.positive()` | `CHECK (budget_cap_sen > 0)` — line 530 |
| **BELI needs a budget** | `.refine(...)` | `ck_beli_has_budget` — line 554 |
| **RM250 ceiling (C-03)** | `.max(25_000)` | `ck_beli_budget_ceiling` — line 555, **and** `rpc_quote_kirim` raises `BUDGET_CAP_EXCEEDED` against `ref.app_config.max_budget_cap_sen = 25000` |
| enum membership | `z.enum([...])` | `ref.kirim_type` column type |
| UUID references | `.uuid()` | foreign keys |

**Every Zod rule has a database counterpart. The Zod layer adds no enforcement
that the database does not already provide.**

The RM250 ceiling is enforced *twice* server-side — once as a CHECK constraint,
once as a configurable `app_config` lookup in the RPC. That second one is the
important detail for what follows: **the ceiling is configuration, not a
constant.** A hardcoded `25_000` in Kotlin would silently disagree the moment
ops changes it.

---

## 3. The three options

### A — Generate Kotlin validation from Zod

Codegen at build time from `schema.ts`.

Against it: it makes the Kotlin client depend on a **TypeScript file in a
reference application we have agreed not to maintain**. It would resurrect
`apps/mobile` as a build-time dependency of the production client, and it
inherits the hardcoded `25_000` rather than reading `app_config`. It also solves
a problem — keeping two client validators in step — that only exists if we keep
two clients.

### B — Server authoritative, Kotlin does presentation pre-validation only

Kotlin validates **format and presence** for immediate feedback: is the email
shaped right, is a field empty, is the number a number. It does **not** encode
business thresholds. Business rules stay where they already are — in constraints
and RPC guards — and the client renders the returned error.

This requires the error surface to be usable, and it already is: the RPCs raise
named errors (`BUDGET_CAP_EXCEEDED`, `CATEGORY_NOT_FOUND`, `SELF_DEALING`,
`STATE_INVALID_TRANSITION`, `FLOAT_LIMIT_EXCEEDED`) and `fromPgError` maps them.
`AppError` in `core/result/` is the Kotlin end of that mapping and already
exists.

For it: matches the architecture as built. Thresholds that live in `app_config`
stay live — the client cannot go stale. No cross-language codegen. Nothing to
drift, because there is only one source of truth.

Against it: a bad budget costs a round trip before the user sees the error. On a
rural connection that is a real cost, though a small one against a wrong answer
shown confidently offline.

### C — Independent Kotlin validation plus contract tests

Duplicate the rules in Kotlin, add tests asserting they match the migrations.

For it: best offline UX — the client can reject RM300 with no network.

Against it: the tests can only compare against a *parsed* migration or a
hardcoded expectation, so they detect drift in the schema file but not in
`app_config`, which is runtime data. It reintroduces exactly the duplication
that made the Zod comment untrue in the first place.

---

## 4. Recommendation — **B**, with one element of C

**Adopt B.** The server is already the sole authority; option B is the only one
that describes what the system actually does rather than adding a second claim
about it.

Take one thing from C: the existing `BackendEnumContractTest` already fails if
the Kotlin enums drift from the migrations. **Extend that pattern to numeric
bounds** — a test that parses `0001_schema.sql` and asserts the Kotlin
presentation hints (weight range, description length) still match the CHECK
constraints. These are stable structural limits, unlike `app_config` values.

Concretely for Phase 3:

- Kotlin validates **format and presence** only — non-empty, numeric, a category
  is selected.
- **No business threshold is hardcoded in Kotlin.** No `25_000`. The RM250
  ceiling is fetched from `ref.app_config` or surfaced by the RPC error.
- Named RPC errors map to `AppError` variants with Malay strings in
  `strings.xml`.
- A contract test asserts Kotlin's presentation bounds against the CHECK
  constraints in the migration.
- `apps/mobile/src/features/kirim/schema.ts` is left **as-is**, and its
  misleading "shared with the Edge Function" comment is noted here rather than
  edited, since `apps/mobile` is frozen reference.

---

## 5. Not decided here

Whether the Edge Functions *should* validate is a separate question. Today they
do not, and the database catches everything, so nothing is unsafe. But a
malformed request currently reaches Postgres before being rejected, which is a
performance and error-message question rather than a security one.

**No production validation architecture has been changed by this document.**
