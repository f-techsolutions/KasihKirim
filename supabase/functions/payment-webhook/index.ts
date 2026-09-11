import { cors } from '../_shared/http.ts';
import { adminClient } from '../_shared/clients.ts';
import { verifyXSignature, normalizeBillplzEvent } from '../_shared/billplz.ts';

/**
 * No JWT. Authenticated per-provider (see below).
 * Deploy with --no-verify-jwt.
 *
 * Idempotency is a UNIQUE constraint, not application logic, so two Edge
 * instances handed the same event cannot both process it. See API.md §4.12.
 *
 * Two providers, two schemes, because that is what each actually sends:
 *   - generic: JSON body, `x-signature` HEADER, whole-body HMAC-SHA256.
 *   - billplz: form-encoded body, `x_signature` FIELD inside the body,
 *     computed over the other fields (see _shared/billplz.ts for the exact
 *     algorithm and its verification caveat). Every provider normalises to
 *     the same {id, status} shape before it reaches rpc_record_webhook, so
 *     nothing past this file needs to know which provider sent the event.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const provider = new URL(req.url).searchParams.get('provider') ?? 'unknown';
  const raw = await req.text();   // raw FIRST -- re-serialising breaks any signature scheme

  let eventId: string;
  let normalizedPayload: Record<string, unknown>;

  if (provider === 'billplz') {
    const secret = Deno.env.get('BILLPLZ_X_SIGNATURE_KEY');
    if (!secret) return new Response('billplz not configured', { status: 401 });

    const { valid, fields } = await verifyXSignature(raw, secret);
    if (!valid) return new Response('invalid signature', { status: 401 });

    const event = normalizeBillplzEvent(fields);
    if (!event.id) return new Response('missing bill id', { status: 400 });
    eventId = event.id;
    normalizedPayload = event;
  } else {
    const sig = req.headers.get('x-signature') ?? '';
    if (!(await validGenericSignature(raw, sig))) {
      return new Response('invalid signature', { status: 401 });
    }
    const event = JSON.parse(raw);
    eventId = event.id;
    normalizedPayload = event;
  }

  const admin = adminClient();

  // Insert-first. Returns false when already seen -- idempotency is a
  // UNIQUE constraint, not application logic.
  const { data: isNew } = await admin.rpc('rpc_record_webhook', {
    p_provider: provider, p_event_id: eventId,
    p_signature_valid: true, p_payload: normalizedPayload,
  });
  if (isNew !== true) return new Response('ok (duplicate)', { status: 200 });

  // Apply under a row lock, guarding against out-of-order delivery.
  // Marking PROCESSED/FAILED happens inside the function.
  const { error: procErr } = await admin.rpc('rpc_apply_payment_event', {
    p_provider: provider, p_event_id: eventId,
  });
  if (procErr) console.error('payment apply failed', provider, eventId, procErr.message);

  // Always 200 on a verified, well-formed event. Provider retries are for
  // genuine failures, not for events we have already handled. Failures are
  // stored and replayed from the admin console; nothing is dropped.
  return new Response('ok', { status: 200 });
});

async function validGenericSignature(raw: string, provided: string): Promise<boolean> {
  const secret = Deno.env.get('PAYMENT_WEBHOOK_SECRET');
  if (!secret || !provided) return false;
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(raw));
  const expected = [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, '0')).join('');
  // Constant-time compare.
  if (expected.length !== provided.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ provided.charCodeAt(i);
  return diff === 0;
}
