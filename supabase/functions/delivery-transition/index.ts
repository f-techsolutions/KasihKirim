import { cors, ok, fail, fromPgError } from '../_shared/http.ts';
import { adminClient, userClient, requireUser } from '../_shared/clients.ts';
import { withIdempotency } from '../_shared/idempotency.ts';

/**
 * The ONLY way a delivery changes state. (BR-904)
 * The client submits an EVENT; the server decides the state. `deliveries` has
 * no UPDATE policy and no UPDATE grant, so no other path exists.
 *
 * The transition itself runs on the USER's client — rpc_delivery_transition
 * derives the actor role from the JWT, never from the payload, so a caller
 * cannot name a role they do not hold. Idempotency bookkeeping runs on
 * service_role.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const requestId = req.headers.get('x-request-id') ?? crypto.randomUUID();
  const idemKey = req.headers.get('idempotency-key');

  try {
    const user = await requireUser(req);
    const body = await req.json();
    const admin = adminClient();

    const result = await withIdempotency(
      admin, idemKey, user.id, 'delivery-transition', body, async () => {
        // Offline capture: the device clock is a hint for ordering, never
        // authority. Skew is recorded rather than silently corrected.
        const meta = {
          geo: body.proof?.geo ?? null,
          offline: body.offline_captured === true,
          client_captured_at: body.proof?.captured_at ?? null,
          clock_skew_seconds: body.proof?.captured_at
            ? Math.round((Date.now() - Date.parse(body.proof.captured_at)) / 1000)
            : null,
        };

        const { data, error } = await userClient(req).rpc('rpc_delivery_transition', {
          p_delivery: body.delivery_id,
          p_event: body.event,
          p_idempotency_key: idemKey,
          p_meta: meta,
        });
        if (error) {
          return { status: 409, body: { error: { code: error.message, request_id: requestId } } };
        }
        return { status: 200, body: { ...data, request_id: requestId } };
      });

    return ok(result.body, result.status);
  } catch (e) {
    const msg = String((e as Error).message);
    if (msg === 'UNAUTHENTICATED') return fail('AUTH_SESSION_EXPIRED', undefined, requestId);
    return fromPgError(msg, requestId);
  }
});
