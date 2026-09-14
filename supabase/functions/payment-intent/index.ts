import { cors, ok, fail, fromPgError } from '../_shared/http.ts';
import { userClient, adminClient, requireUser } from '../_shared/clients.ts';
import { createBill } from '../_shared/billplz.ts';

/**
 * Opens (or re-fetches) a hosted payment page for a marketplace order
 * already checked out with a non-COD method. Sandbox-only: BILLPLZ_BASE_URL
 * defaults to Billplz's sandbox host (see _shared/billplz.ts), and
 * ref.app_config.payment_methods_enabled stays ["COD"] in production, so
 * rpc_prepare_billplz_bill (called below) refuses this call outright on any
 * project where prepaid has not been deliberately enabled.
 *
 * POST { order_id: uuid }
 */
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const requestId = req.headers.get('x-request-id') ?? crypto.randomUUID();

  try {
    await requireUser(req);
    const { order_id } = await req.json();
    if (!order_id) return fromPgError('ORDER_NOT_FOUND', requestId);

    // Runs as the buyer: ownership and payment-state checks live in the RPC,
    // not here. Never trust order_id -> buyer_id from the request alone.
    const { data: prep, error: prepErr } = await userClient(req)
      .rpc('rpc_prepare_billplz_bill', { p_order: order_id });
    if (prepErr) return fromPgError(prepErr.message, requestId);

    // Idempotent: a bill already exists for this payment, hand back the
    // same URL rather than asking Billplz to mint a second one.
    if (prep.already_created) {
      return ok({ checkout_url: prep.checkout_url, request_id: requestId });
    }

    const collectionId = Deno.env.get('BILLPLZ_COLLECTION_ID');
    const apiKey = Deno.env.get('BILLPLZ_API_KEY');
    const callbackBase = Deno.env.get('SUPABASE_URL');
    const redirectUrl = Deno.env.get('BILLPLZ_REDIRECT_URL')
      ?? 'https://kasihkirim.app/payment/return';
    if (!collectionId || !apiKey || !callbackBase) {
      console.error('Billplz not configured: missing collection id, api key, or SUPABASE_URL');
      return fromPgError('PAYMENT_METHOD_NOT_ENABLED', requestId);
    }

    const bill = await createBill({
      collectionId,
      apiKey,
      amountSen: prep.amount_sen,
      name: prep.name,
      mobile: prep.mobile ?? '',
      description: `KasihKirim ${prep.reference_code}`,
      referenceCode: prep.reference_code,
      callbackUrl: `${callbackBase}/functions/v1/payment-webhook?provider=billplz`,
      redirectUrl,
    });

    // service_role: only the Edge Function that actually talked to Billplz
    // may record what Billplz returned. Never let a client set its own
    // provider_ref or checkout_url.
    const { error: recErr } = await adminClient()
      .rpc('rpc_record_billplz_bill', {
        p_payment_id: prep.payment_id, p_bill_id: bill.id, p_checkout_url: bill.url,
      });
    if (recErr) console.error('rpc_record_billplz_bill failed', prep.payment_id, recErr.message);

    return ok({ checkout_url: bill.url, request_id: requestId });
  } catch (e) {
    const msg = String((e as Error).message);
    if (msg === 'UNAUTHENTICATED') return fail('AUTH_SESSION_EXPIRED', undefined, requestId);
    return fromPgError(msg, requestId);
  }
});
