export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, idempotency-key, x-request-id, x-app-version, x-client-locale, x-data-saver',
};

type ErrShape = {
  code: string; message: string; message_ms: string;
  details?: unknown; retriable: boolean;
};

/** Localised server-side: the client may be running a four-month-old string
 *  table. See API.md §2.2. */
const CATALOG: Record<string, [string, string, number, boolean]> = {
  CAPACITY_EXCEEDED:        ['This trip no longer has room for your parcel.', 'Trip ini sudah tiada ruang untuk kiriman awak.', 409, false],
  TRIP_NOT_BOARDING:        ['This trip is no longer accepting cargo.', 'Trip ini sudah tidak menerima muatan.', 409, false],
  QUOTE_EXPIRED:            ['This price has expired. Please try again.', 'Harga ini sudah luput. Sila cuba semula.', 410, false],
  QUOTE_ALREADY_USED:       ['This price was already used.', 'Harga ini sudah digunakan.', 409, false],
  BUDGET_CAP_EXCEEDED:      ['Cost is above the budget. Ask the requester first.', 'Kos melebihi bajet. Tanya pemohon dahulu.', 422, false],
  FLOAT_LIMIT_EXCEEDED:     ['You are holding too much cash or advance already.', 'Awak sudah pegang terlalu banyak wang atau pendahuluan.', 422, false],
  STATE_INVALID_TRANSITION: ['That action is not available right now.', 'Tindakan itu tidak tersedia sekarang.', 409, false],
  STATE_ACTOR_NOT_PERMITTED:['You are not allowed to do that.', 'Awak tiada kebenaran untuk itu.', 403, false],
  PROOF_INVALID_SIGNATURE:  ['This code is not valid.', 'Kod ini tidak sah.', 400, false],
  PROOF_NONCE_CONSUMED:     ['This code was already used.', 'Kod ini sudah digunakan.', 409, false],
  PROOF_OTP_INVALID:        ['Wrong code. Please try again.', 'Kod salah. Sila cuba lagi.', 400, false],
  PROOF_OTP_LOCKED:         ['Too many attempts. Ask for a new code.', 'Terlalu banyak cubaan. Minta kod baharu.', 429, false],
  IDEMPOTENCY_KEY_REUSE:    ['Conflicting repeat request.', 'Permintaan berulang yang bercanggah.', 409, false],
  AUTH_SESSION_EXPIRED:     ['Your session has expired. Please sign in again.', 'Sesi awak sudah tamat. Sila log masuk semula.', 401, false],
  ORDER_NOT_FOUND:          ['This order could not be found.', 'Pesanan ini tidak dijumpai.', 404, false],
  PAYMENT_METHOD_NOT_ENABLED: ['This payment method is not available yet.', 'Kaedah pembayaran ini belum tersedia.', 422, false],
  PAYMENT_METHOD_UNKNOWN:   ['Unrecognised payment method.', 'Kaedah pembayaran tidak dikenali.', 422, false],
  PAYMENT_METHOD_IS_COD:    ['This order is Cash on Delivery and needs no online payment.', 'Pesanan ini Bayar Semasa Terima dan tidak perlu bayaran dalam talian.', 422, false],
  PAYMENT_NOT_PENDING:      ['This payment has already moved on and cannot be paid again.', 'Bayaran ini sudah berubah status dan tidak boleh dibayar semula.', 409, false],
  PAYMENT_MISSING:          ['No payment record exists for this order.', 'Tiada rekod bayaran untuk pesanan ini.', 404, false],
  BILLPLZ_CREATE_BILL_FAILED: ['Could not start the payment. Please try again shortly.', 'Tidak dapat memulakan bayaran. Sila cuba sebentar lagi.', 502, true],
  INTERNAL:                 ['Something went wrong. Please try again.', 'Ada masalah. Sila cuba lagi.', 500, true],
};

export function fail(code: string, details?: unknown, requestId = '') {
  const [en, ms, status, retriable] = CATALOG[code] ?? CATALOG.INTERNAL!;
  const error: ErrShape & { request_id: string } = {
    code, message: en, message_ms: ms, details, retriable, request_id: requestId,
  };
  return new Response(JSON.stringify({ error }), {
    status, headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

export function ok(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

/** Maps a Postgres exception message onto our error catalogue. The database
 *  raises these by name, so the invariant and the API stay in step. */
export function fromPgError(msg: string, requestId = '') {
  for (const code of Object.keys(CATALOG)) {
    if (msg.includes(code)) return fail(code, undefined, requestId);
  }
  if (msg.includes('BR-913')) return fail('BUDGET_CAP_EXCEEDED', undefined, requestId);
  if (msg.includes('ck_carrier_exposure')) return fail('FLOAT_LIMIT_EXCEEDED', undefined, requestId);
  if (msg.includes('ck_trip_') && msg.includes('capacity')) return fail('CAPACITY_EXCEEDED', undefined, requestId);
  return fail('INTERNAL', { hint: msg.slice(0, 200) }, requestId);
}
