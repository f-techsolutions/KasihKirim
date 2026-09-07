# Offline Architecture

Rural Sabah has intermittent coverage. The Expo client already solved this; the
design below is what it does today and what the Kotlin client will do in Phase 6.

**Phase 1 implements none of this.** The architecture is documented first so the
Kotlin implementation is a port rather than a reinvention.

## 1. What the Expo client does today

Source: `apps/mobile/src/core/db/schema.ts`, `src/core/sync/outbox.ts`.

### SQLite schema

```sql
PRAGMA journal_mode = WAL;

outbox(id, created_at, endpoint, method, payload, idempotency_key UNIQUE,
       depends_on REFERENCES outbox(id), entity_type, entity_id,
       attempts, next_attempt_at, status, last_error)
INDEX ix_outbox_ready ON outbox(status, next_attempt_at)

media_queue(id, local_uri, bucket, remote_path, bytes, outbox_id, status)
cache_entities(table_name, id, data, updated_at, cached_at)  PK (table_name, id)
sync_cursors(table_name, cursor)
```

### Four behaviours worth preserving

**Idempotency key at birth.** The key is generated when the action is *queued*,
not when it is *sent*. A retry after an ambiguous timeout reuses the same key, so
the server deduplicates instead of creating a second delivery. This is the single
most important property here.

**Exponential backoff with jitter.**
`min(2^attempts × 1000ms, 300_000) × (0.8 + random × 0.4)`. The jitter matters:
without it every phone in a village that just regained signal retries in lockstep.

**Dependency ordering.** `depends_on` lets "confirm handover" wait for "create
delivery". A batch of 20 is drained oldest-first, and a row whose dependency has
not reached `SENT` is skipped, not failed.

**Bounded give-up.** After 10 attempts the row becomes `FAILED` and surfaces to
the user, rather than retrying forever and hiding a real problem.

## 2. Kotlin equivalent — Phase 6

| Expo | Kotlin |
|---|---|
| `expo-sqlite` + raw SQL | **Room** — same table shapes, migrations |
| Manual `flush()` on connectivity | **WorkManager** with `NetworkType.CONNECTED` |
| `Crypto.randomUUID()` at enqueue | `UUID.randomUUID()` at enqueue — unchanged semantics |
| `nextDelay()` | Same formula. Not `BackoffPolicy.EXPONENTIAL` alone — it has no jitter |
| `depends_on` skip | Same, enforced in the DAO query |
| `cache_entities` | Room entities + `updated_at` cursor |

WorkManager is chosen over a bare coroutine loop because it survives process
death, which is the case that matters on a low-RAM phone.

## 3. What is deliberately NOT offline

Money and state transitions are **server-authoritative**. The client queues an
*intent* (`rpc_delivery_transition` with an idempotency key) and renders whatever
status comes back. It never computes a balance, never advances a state locally,
and never shows a transition as complete before the server confirms it.

Quotes are cached with their `expires_at` and shown as stale past it — never
re-priced on device.

## 4. Honest current state

Phase 1 is **online-only**. There is no queue, no cache and no retry beyond what
the Supabase SDK does. §18 of the brief is explicit: do not pretend the app is
offline-capable when it is not. The UI shows a plain network error.
