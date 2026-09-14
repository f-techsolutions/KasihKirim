// Run with: deno test supabase/functions/_shared/webhook_audit.test.ts
//
// tryExtractId/safeParse are pure and fully covered here. logRejectedWebhook
// is a thin best-effort wrapper around a Supabase RPC call -- its only
// interesting behavior (never throwing past a logging failure) is exercised
// with a fake admin client below; it needs no network access to verify.

import { assertEquals } from 'jsr:@std/assert@1';
import { logRejectedWebhook, safeParse, tryExtractId } from './webhook_audit.ts';

Deno.test('tryExtractId reads the id field out of well-formed JSON', () => {
  assertEquals(tryExtractId('{"id":"evt_1","status":"failed"}'), 'evt_1');
});

Deno.test('tryExtractId returns undefined for malformed JSON', () => {
  assertEquals(tryExtractId('not json at all'), undefined);
});

Deno.test('tryExtractId returns undefined when id is missing or not a string', () => {
  assertEquals(tryExtractId('{"status":"failed"}'), undefined);
  assertEquals(tryExtractId('{"id":123}'), undefined);
});

Deno.test('safeParse returns the parsed object for well-formed JSON', () => {
  assertEquals(safeParse('{"a":1}'), { a: 1 });
});

Deno.test('safeParse falls back to a raw-body wrapper for malformed JSON', () => {
  const result = safeParse('<not json>');
  assertEquals(result.raw, '<not json>');
});

Deno.test('logRejectedWebhook calls rpc_record_webhook with signature_valid=false, namespaced under rejected:', async () => {
  let called: { name: string; args: Record<string, unknown> } | null = null;
  const fakeAdmin = {
    // deno-lint-ignore no-explicit-any
    rpc: (name: string, args: Record<string, unknown>) => {
      called = { name, args };
      return Promise.resolve({ data: true, error: null });
    },
  };

  await logRejectedWebhook(fakeAdmin, 'billplz', 'bill_123', { id: 'bill_123' });

  assertEquals(called?.name, 'rpc_record_webhook');
  assertEquals(called?.args.p_provider, 'billplz');
  assertEquals(called?.args.p_event_id, 'rejected:bill_123');
  assertEquals(called?.args.p_signature_valid, false);
});

Deno.test('logRejectedWebhook falls back to a fresh id when none is available, never throwing', async () => {
  const fakeAdmin = {
    rpc: () => Promise.resolve({ data: true, error: null }),
  };
  // Must not throw even with an undefined id.
  await logRejectedWebhook(fakeAdmin, 'unknown', undefined, {});
});

Deno.test('logRejectedWebhook swallows an RPC failure rather than throwing', async () => {
  const fakeAdmin = {
    rpc: () => Promise.reject(new Error('connection refused')),
  };
  // Must not throw or reject -- a logging failure must never turn into a
  // 500 for the webhook caller.
  await logRejectedWebhook(fakeAdmin, 'billplz', 'bill_1', {});
});
