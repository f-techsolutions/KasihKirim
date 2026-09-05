import { createHash } from 'node:crypto';
import type { SupabaseClient } from 'jsr:@supabase/supabase-js@2';

/**
 * Same key + same body      -> replay the stored response.
 * Same key + different body -> 409.
 * Unknown key               -> process, then store.  See API.md §7.
 *
 * Goes through public.rpc_idem_* because `internal` is NOT on PostgREST's
 * exposed-schema list — unreachable even with the service-role key.
 */
export async function withIdempotency(
  admin: SupabaseClient, key: string | null, actorId: string, endpoint: string,
  body: unknown, handler: () => Promise<{ status: number; body: unknown }>,
): Promise<{ status: number; body: unknown; replayed: boolean }> {
  if (!key) return { ...(await handler()), replayed: false };

  const hash = createHash('sha256').update(JSON.stringify(body ?? {})).digest('hex');

  const { data: prior } = await admin.rpc('rpc_idem_lookup', {
    p_key: key, p_request_hash: hash,
  });

  if (prior?.conflict) {
    return {
      status: 409,
      body: { error: { code: 'IDEMPOTENCY_KEY_REUSE',
                       message_ms: 'Permintaan berulang yang bercanggah.' } },
      replayed: true,
    };
  }
  if (prior?.replayed) {
    return { status: prior.status_code ?? 200, body: prior.response_body, replayed: true };
  }

  const result = await handler();

  await admin.rpc('rpc_idem_store', {
    p_key: key, p_actor: actorId, p_endpoint: endpoint,
    p_request_hash: hash, p_response: result.body, p_status: result.status,
  });
  return { ...result, replayed: false };
}
