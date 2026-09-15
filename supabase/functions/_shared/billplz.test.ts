// Run with: deno test supabase/functions/_shared/billplz.test.ts
//
// These are internal-consistency tests, not conformance tests: they prove
// verifyXSignature() correctly implements the algorithm documented in
// billplz.ts's own header, and that tampering is detected. They do NOT
// prove that algorithm matches what Billplz's real service actually sends
// -- this environment has no network access to Billplz to obtain a real
// reference vector. See billplz.ts's verification note before trusting this
// against a live sandbox transaction.

import { assertEquals } from 'jsr:@std/assert@1';
import { verifyXSignature, normalizeBillplzEvent } from './billplz.ts';

async function sign(source: string, key: string): Promise<string> {
  const cryptoKey = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(key),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', cryptoKey, new TextEncoder().encode(source));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.test('verifyXSignature accepts a correctly-signed callback', async () => {
  const key = 'test-x-signature-key';
  const source = 'idbill_123collection_idcol_1paidtruestatepaidamount5000';
  const sig = await sign(source, key);
  const body = `id=bill_123&collection_id=col_1&paid=true&state=paid&amount=5000&x_signature=${sig}`;

  const { valid, fields } = await verifyXSignature(body, key);
  assertEquals(valid, true);
  assertEquals(fields.id, 'bill_123');
});

Deno.test('verifyXSignature rejects a tampered amount', async () => {
  const key = 'test-x-signature-key';
  const source = 'idbill_123collection_idcol_1paidtruestatepaidamount5000';
  const sig = await sign(source, key);
  // Amount changed after signing -- the signature no longer matches.
  const body = `id=bill_123&collection_id=col_1&paid=true&state=paid&amount=999999&x_signature=${sig}`;

  const { valid } = await verifyXSignature(body, key);
  assertEquals(valid, false);
});

Deno.test('verifyXSignature rejects a wrong key', async () => {
  const source = 'idbill_123collection_idcol_1paidtruestatepaidamount5000';
  const sig = await sign(source, 'the-real-key');
  const body = `id=bill_123&collection_id=col_1&paid=true&state=paid&amount=5000&x_signature=${sig}`;

  const { valid } = await verifyXSignature(body, 'a-different-key');
  assertEquals(valid, false);
});

Deno.test('verifyXSignature rejects a missing x_signature', async () => {
  const body = 'id=bill_123&collection_id=col_1&paid=true';
  const { valid } = await verifyXSignature(body, 'any-key');
  assertEquals(valid, false);
});

Deno.test('normalizeBillplzEvent maps paid=true to status=paid', () => {
  const event = normalizeBillplzEvent({ id: 'bill_1', paid: 'true', state: 'paid' });
  assertEquals(event.status, 'paid');
  assertEquals(event.reference, 'bill_1');
});

Deno.test('normalizeBillplzEvent maps paid=false to the raw state', () => {
  const event = normalizeBillplzEvent({ id: 'bill_2', paid: 'false', state: 'due' });
  assertEquals(event.status, 'due');
});
