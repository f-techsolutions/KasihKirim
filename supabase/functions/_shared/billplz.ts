/**
 * Billplz API v3 adapter. Sandbox by design: BILLPLZ_BASE_URL defaults to
 * the sandbox host, and nothing in this repo, this function, or any
 * migration sets it to the production host. Switching a deployed project to
 * live Billplz is a deliberate secret change outside of this code, not
 * something a code change here can silently do.
 *
 * ── Verification note ───────────────────────────────────────────────────
 * This environment has no outbound network access to billplz.com, so the
 * exact request/response shape and the X-Signature algorithm below are
 * implemented from documented knowledge of Billplz API v3, NOT verified
 * against a live call or a real sandbox callback. Before this is trusted
 * with a single real sandbox transaction:
 *   1. Create one real bill against a real Billplz sandbox collection and
 *      confirm the response fields below match (id, url).
 *   2. Trigger one real callback (Billplz's sandbox dashboard can resend a
 *      bill's webhook) and confirm computeXSignature() reproduces the
 *      x_signature Billplz actually sent, byte for byte.
 * Both functions are small and isolated specifically so that fixing either,
 * if the real API differs, is a one-function change, not a redesign.
 */

const BASE_URL = Deno.env.get('BILLPLZ_BASE_URL') ?? 'https://www.billplz-sandbox.com/api/v3';

export type BillplzBill = {
  id: string;
  url: string;
  state: string;
  paid: boolean;
  amount: number;
};

/** Creates a bill. amount_sen is already in the smallest currency unit
 *  (sen), which is what Billplz's `amount` field expects -- no conversion. */
export async function createBill(args: {
  collectionId: string;
  apiKey: string;
  amountSen: number;
  name: string;
  mobile: string;
  description: string;
  referenceCode: string;
  callbackUrl: string;
  redirectUrl: string;
}): Promise<BillplzBill> {
  const body = new URLSearchParams({
    collection_id: args.collectionId,
    email: '',                 // optional when mobile is present
    mobile: args.mobile,
    name: args.name,
    amount: String(args.amountSen),
    description: args.description.slice(0, 200),
    callback_url: args.callbackUrl,
    redirect_url: args.redirectUrl,
    reference_1_label: 'Order',
    reference_1: args.referenceCode,
  });

  const res = await fetch(`${BASE_URL}/bills`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      // HTTP Basic auth: API secret key as username, empty password.
      Authorization: 'Basic ' + btoa(`${args.apiKey}:`),
    },
    body,
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`BILLPLZ_CREATE_BILL_FAILED: ${res.status} ${text.slice(0, 300)}`);
  }
  return await res.json();
}

/** Verifies a callback's X-Signature. Billplz posts application/
 *  x-www-form-urlencoded, with the signature computed over every field
 *  EXCEPT x_signature, in the order the fields were sent, as
 *  "key1value1|key2value2|...", HMAC-SHA256 with the X Signature Key (a
 *  separate secret from the API key, found on the collection/account
 *  settings page) -- not sorted alphabetically. Preserving receipt order
 *  matters: this reads the raw body with URLSearchParams, which iterates in
 *  the order fields appear, rather than through an object that could
 *  reorder keys. */
export async function verifyXSignature(
  rawBody: string, xSignatureKey: string,
): Promise<{ valid: boolean; fields: Record<string, string> }> {
  const params = new URLSearchParams(rawBody);
  const fields: Record<string, string> = {};
  const parts: string[] = [];
  let provided = '';

  for (const [key, value] of params) {
    if (key === 'x_signature') { provided = value; continue; }
    fields[key] = value;
    parts.push(key + value);
  }
  if (!provided) return { valid: false, fields };

  const source = parts.join('|');
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(xSignatureKey),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(source));
  const expected = [...new Uint8Array(mac)]
    .map((b) => b.toString(16).padStart(2, '0')).join('');

  if (expected.length !== provided.length) return { valid: false, fields };
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ provided.charCodeAt(i);
  return { valid: diff === 0, fields };
}

/** Normalises a Billplz callback into the {id, status, reference} shape
 *  internal.fn_apply_payment_event already reads for every provider (see
 *  fn_map_provider_status, 0004: "one place to add a gateway"). Billplz has
 *  no single "status" field -- it has `state` (due/paid) and `paid`
 *  (true/false) -- so that mapping happens here, at the adapter boundary,
 *  and nothing downstream needs to know Billplz's field names. */
export function normalizeBillplzEvent(fields: Record<string, string>) {
  const paid = fields.paid === 'true';
  const status = paid ? 'paid' : (fields.state ?? 'pending');
  return {
    id: fields.id,
    status,
    reference: fields.id,      // internal.payments.provider_ref is the bill id
    raw: fields,
  };
}
