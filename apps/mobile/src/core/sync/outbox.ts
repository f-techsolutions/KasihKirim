import * as Crypto from 'expo-crypto';
import { db } from '../db/schema';
import { supabase } from '../api/supabase';

/**
 * The idempotency key is generated HERE - when the user acts - not when the
 * request is sent. A handover confirmed in a valley with no signal and retried
 * eleven times over three days carries one key and produces one effect.
 * See API.md section 7.
 */
export function enqueue(args: {
  endpoint: string; method: 'POST' | 'PATCH';
  payload: unknown; entityType: string; entityId: string; dependsOn?: string;
}): string {
  const id = Crypto.randomUUID();
  db.runSync(
    `INSERT INTO outbox (id, created_at, endpoint, method, payload,
       idempotency_key, depends_on, entity_type, entity_id, next_attempt_at)
     VALUES (?,?,?,?,?,?,?,?,?,?)`,
    [id, Date.now(), args.endpoint, args.method, JSON.stringify(args.payload),
     Crypto.randomUUID(), args.dependsOn ?? null,
     args.entityType, args.entityId, Date.now()],
  );
  return id;
}

export function pendingCount(): number {
  const r = db.getFirstSync<{ n: number }>(
    `SELECT count(*) n FROM outbox WHERE status IN ('PENDING','FAILED')`);
  return r?.n ?? 0;
}

/** Backoff 2^n seconds capped at 5 min, with jitter so a village coming back
 *  online does not produce a synchronised retry storm. */
function nextDelay(attempts: number): number {
  const base = Math.min(2 ** attempts * 1000, 300_000);
  return base * (0.8 + Math.random() * 0.4);
}

export async function flush(): Promise<void> {
  const rows = db.getAllSync<any>(
    `SELECT * FROM outbox WHERE status IN ('PENDING','FAILED')
       AND next_attempt_at <= ? ORDER BY created_at ASC LIMIT 20`, [Date.now()]);

  for (const row of rows) {
    if (row.depends_on) {
      const dep = db.getFirstSync<any>(
        `SELECT status FROM outbox WHERE id = ?`, [row.depends_on]);
      if (dep && dep.status !== 'SENT') continue;     // preserve ordering
    }
    try {
      const { error } = await supabase.functions.invoke(row.endpoint, {
        body: JSON.parse(row.payload),
        headers: { 'Idempotency-Key': row.idempotency_key },
      });
      if (error) throw error;
      db.runSync(`UPDATE outbox SET status='SENT' WHERE id=?`, [row.id]);
    } catch (e: any) {
      const attempts = row.attempts + 1;
      // Give up after 10 attempts, but never silently discard - surface it.
      const status = attempts >= 10 ? 'FAILED' : 'PENDING';
      db.runSync(
        `UPDATE outbox SET attempts=?, next_attempt_at=?, status=?, last_error=? WHERE id=?`,
        [attempts, Date.now() + nextDelay(attempts), status, String(e?.message ?? e), row.id]);
    }
  }
}
