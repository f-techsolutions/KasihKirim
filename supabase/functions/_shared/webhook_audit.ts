/**
 * Best-effort audit logging for a webhook callback that fails signature
 * verification. Split out of payment-webhook/index.ts (which calls
 * Deno.serve() at module scope, so importing it directly for a unit test
 * would bind a real port) so these three pure/near-pure helpers stay
 * testable the same way _shared/billplz.ts's own functions are.
 */

/** Records a rejected (signature_valid=false) callback so a forged or
 *  corrupted webhook leaves an audit trail instead of vanishing at the 401 --
 *  found in review: the success path already logs every event via
 *  rpc_record_webhook, but a failed verification returned straight to the
 *  caller with nothing recorded. Best-effort: a logging failure must never
 *  turn into a 500 for what is, from the caller's own signature's evidence,
 *  not really our caller. Never collides with a real event's own row --
 *  provider_event_id is namespaced under 'rejected:' either way, and a
 *  missing id falls back to a fresh UUID so distinct bad attempts don't
 *  overwrite each other's audit row via the (provider, event_id) unique
 *  constraint. */
export async function logRejectedWebhook(
  // deno-lint-ignore no-explicit-any
  admin: any, provider: string, rawId: string | undefined, payload: unknown,
): Promise<void> {
  try {
    const id = `rejected:${rawId ?? crypto.randomUUID()}`;
    await admin.rpc('rpc_record_webhook', {
      p_provider: provider, p_event_id: id,
      p_signature_valid: false, p_payload: payload ?? {},
    });
  } catch (err) {
    console.error('failed to log rejected webhook', provider, err);
  }
}

export function tryExtractId(raw: string): string | undefined {
  try {
    const parsed = JSON.parse(raw);
    return typeof parsed?.id === 'string' ? parsed.id : undefined;
  } catch {
    return undefined;
  }
}

export function safeParse(raw: string): Record<string, unknown> {
  try {
    return JSON.parse(raw);
  } catch {
    return { raw: raw.slice(0, 500) };
  }
}
