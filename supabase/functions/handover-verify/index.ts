import { cors, ok, fail } from '../_shared/http.ts';
import { adminClient, requireUser } from '../_shared/clients.ts';

/**
 * Verifies a handover proof captured OFFLINE and submitted later.
 * The scanner had no connectivity at scan time and could validate nothing, so
 * all authority sits here. See ARCHITECTURE.md §8.
 *
 * Replay defence is a UNIQUE INDEX on internal.handover_nonces, not a code
 * path: two Edge instances handed the same token cannot both succeed.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const requestId = req.headers.get('x-request-id') ?? crypto.randomUUID();

  try {
    const user = await requireUser(req);
    const { delivery_id, leg, method, token, code, geo } = await req.json();
    const admin = adminClient();

    let quality: 'STRONG' | 'WEAK' | 'SUSPECT' = 'STRONG';
    const flags: string[] = [];

    if (method === 'QR') {
      const parts = String(token ?? '').split('.');
      if (parts.length !== 3 || parts[0] !== 'kk1') {
        return fail('PROOF_INVALID_SIGNATURE', undefined, requestId);
      }
      const payload = JSON.parse(atob(parts[1]!));
      const sigOk = await verifyEd25519(parts[1]!, parts[2]!);
      if (!sigOk) return fail('PROOF_INVALID_SIGNATURE', undefined, requestId);
      if (payload.d !== delivery_id || payload.l !== leg) {
        return fail('PROOF_INVALID_SIGNATURE', undefined, requestId);
      }

      // First use wins. The unique index decides, not this function — two
      // Edge instances handed the same token cannot both succeed.
      const { data: fresh } = await admin.rpc('rpc_consume_nonce', {
        p_nonce: payload.n, p_delivery: delivery_id, p_leg: leg, p_by: user.id,
      });
      if (fresh !== true) {
        await admin.rpc('rpc_risk_signal', {
          p_subject_type: 'delivery', p_subject_id: delivery_id,
          p_signal: 'QR_REPLAY_ATTEMPT', p_severity: 5,
          p_details: { by: user.id, request_id: requestId },
        });
        return fail('PROOF_NONCE_CONSUMED', undefined, requestId);
      }
    }

    if (method === 'OTP') {
      const { data: hc } = await admin.from('handover_codes')
        .select('*').eq('delivery_id', delivery_id).eq('leg', leg)
        .is('consumed_at', null).maybeSingle();
      if (!hc) return fail('PROOF_OTP_INVALID', undefined, requestId);
      if (hc.locked_at || hc.attempts >= hc.max_attempts) {
        return fail('PROOF_OTP_LOCKED', undefined, requestId);
      }
      const hash = await hmac(String(code));
      if (hash !== hc.code_hash) {
        const attempts = hc.attempts + 1;
        await admin.from('handover_codes').update({
          attempts, locked_at: attempts >= hc.max_attempts ? new Date().toISOString() : null,
        }).eq('id', hc.id);
        return fail('PROOF_OTP_INVALID',
          { attempts_remaining: hc.max_attempts - attempts }, requestId);
      }
      await admin.from('handover_codes')
        .update({ consumed_at: new Date().toISOString() }).eq('id', hc.id);
    }

    if (method === 'PHOTO') { quality = 'WEAK'; flags.push('PHOTO_ONLY'); }

    // Rural GPS is genuinely unreliable - canopy, valleys, cheap chipsets.
    // A geofence miss FLAGS, it does not block: blocking would punish honest
    // carriers far more often than it would catch fraud. We slow the money,
    // not the parcel.
    if (geo?.is_mock) { quality = 'SUSPECT'; flags.push('MOCK_LOCATION'); }
    else if (geo?.distance_to_node_m > 5000) { quality = 'SUSPECT'; flags.push('GEO_MISMATCH'); }
    else if (geo?.distance_to_node_m > 500) { flags.push('GEO_LOOSE'); }

    await admin.from('proofs').insert({
      delivery_id, leg, method, quality,
      geog: geo ? `POINT(${geo.lng} ${geo.lat})` : null,
      geo_accuracy_m: geo?.accuracy_m ?? null,
      distance_to_node_m: geo?.distance_to_node_m ?? null,
      captured_at: geo?.captured_at ?? new Date().toISOString(),
      verified_by: user.id,
      is_offline_capture: !!geo?.offline,
      flags,
    });

    return ok({ verified: true, proof_quality: quality, flags, request_id: requestId });
  } catch (e) {
    return fail('INTERNAL', { hint: String((e as Error).message) }, requestId);
  }
});

/** Ed25519 public key from Vault. Two keys stay valid across a rotation window
 *  because a carrier may hold a token issued before rotation and be out of
 *  coverage until after it. See SECURITY.md §12.1. */
async function verifyEd25519(payloadB64: string, sigB64: string): Promise<boolean> {
  const keys = [Deno.env.get('QR_PUBLIC_KEY'), Deno.env.get('QR_PUBLIC_KEY_PREVIOUS')]
    .filter(Boolean) as string[];
  for (const raw of keys) {
    try {
      const key = await crypto.subtle.importKey(
        'raw', b64(raw), { name: 'Ed25519' }, false, ['verify']);
      const okSig = await crypto.subtle.verify(
        'Ed25519', key, b64(sigB64), new TextEncoder().encode(payloadB64));
      if (okSig) return true;
    } catch { /* try the next key */ }
  }
  return false;
}

async function hmac(code: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(Deno.env.get('OTP_PEPPER')!),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(code));
  return [...new Uint8Array(sig)].map((x) => x.toString(16).padStart(2, '0')).join('');
}

function b64(s: string): Uint8Array {
  return Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
}
