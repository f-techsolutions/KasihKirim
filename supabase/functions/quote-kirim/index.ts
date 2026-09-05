import { cors, ok, fromPgError, fail } from '../_shared/http.ts';
import { userClient, requireUser } from '../_shared/clients.ts';

/**
 * The client sends WHAT it wants, never HOW MUCH it costs. (BR-900)
 *
 * Called with the USER's client, not service_role: rpc_quote_kirim reads
 * auth.uid() to set the requester, so the caller's JWT must be present. A
 * service-role call would have a NULL uid and raise UNAUTHENTICATED.
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const requestId = req.headers.get('x-request-id') ?? crypto.randomUUID();

  try {
    await requireUser(req);
    const b = await req.json();

    const { data, error } = await userClient(req).rpc('rpc_quote_kirim', {
      p_kirim_type: b.kirim_type,
      p_category_slug: b.category_slug,
      p_est_weight_grams: b.est_weight_grams,
      p_origin_node: b.origin_node_id,
      p_dest_node: b.dest_node_id,
      p_budget_cap_sen: b.budget_cap_sen ?? 0,
      p_volume_cm3: b.volume_cm3 ?? 8000,
      p_handling_flags: b.handling_flags ?? [],
      p_payment_method: b.payment_method ?? 'COD',
    });
    if (error) return fromPgError(error.message, requestId);

    return ok({ ...data, request_id: requestId });
  } catch (e) {
    const msg = String((e as Error).message);
    if (msg === 'UNAUTHENTICATED') return fail('AUTH_SESSION_EXPIRED', undefined, requestId);
    return fromPgError(msg, requestId);
  }
});
