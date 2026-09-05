import { cors } from '../_shared/http.ts';
import { adminClient } from '../_shared/clients.ts';

/**
 * No JWT. Authenticated by HMAC over the RAW body.
 * Deploy with --no-verify-jwt.
 *
 * Idempotency is a UNIQUE constraint, not application logic, so two Edge
 * instances handed the same event cannot both process it. See API.md §4.12.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  // 1. Raw body FIRST. Re-serialising a parsed body breaks the signature.
  const raw = await req.text();
  const sig = req.headers.get('x-signature') ?? '';
  const provider = new URL(req.url).searchParams.get('provider') ?? 'unknown';

  // 2. Verify before parsing anything.
  if (!(await validSignature(raw, sig))) {
    return new Response('invalid signature', { status: 401 });
  }

  const event = JSON.parse(raw);
  const admin = adminClient();

  // 3. Insert-first. Returns false when already seen — idempotency is a
  //    UNIQUE constraint, not application logic.
  const { data: isNew } = await admin.rpc('rpc_record_webhook', {
    p_provider: provider, p_event_id: event.id,
    p_signature_valid: true, p_payload: event,
  });
  if (isNew !== true) return new Response('ok (duplicate)', { status: 200 });

  // 4. Apply under a row lock, guarding against out-of-order delivery.
  //    Marking PROCESSED/FAILED happens inside the function.
  const { error: procErr } = await admin.rpc('rpc_apply_payment_event', {
    p_provider: provider, p_event_id: event.id,
  });
  if (procErr) console.error('payment apply failed', provider, event.id, procErr.message);

  // 5. Always 200 on a verified, well-formed event. Provider retries are for
  //    genuine failures, not for events we have already handled. Failures are
  //    stored and replayed from the admin console; nothing is dropped.
  return new Response('ok', { status: 200 });
});

async function validSignature(raw: string, provided: string): Promise<boolean> {
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
