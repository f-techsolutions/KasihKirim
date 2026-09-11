# KasihKirim — API Design

Implements [`ARCHITECTURE.md`](./ARCHITECTURE.md) §3 over the schema in [`DATABASE.md`](./DATABASE.md). Authorisation detail lives in [`SECURITY.md`](./SECURITY.md).

---

## 1. Three surfaces, one rule

| Surface | Base | Use for | Never use for |
|---|---|---|---|
| **PostgREST** | `https://{ref}.supabase.co/rest/v1` | Authorised reads guarded by RLS | Anything that writes money or state |
| **RPC** (`SECURITY DEFINER` functions) | `.../rest/v1/rpc/{fn}` | Transactional writes needing a database invariant | External I/O |
| **Edge Functions** (Deno) | `.../functions/v1/{fn}` | External I/O, webhooks, orchestration, signed tokens, admin | Long-lived state |

**The rule:** *if it touches money or delivery state, it is RPC or Edge. If it is a read, it is PostgREST.*

This is not stylistic. PostgREST has no cold start and costs nothing per call — at RM 12.50 revenue per order (`PRD.md` §16.1), routing reads through Edge Functions would be a measurable drag on margin. Reads go the cheap way; writes go the safe way.

---

## 2. Conventions

### 2.1 Headers

| Header | Direction | Required | Notes |
|---|---|---|---|
| `Authorization: Bearer <jwt>` | → | Yes (except webhooks) | Supabase access token |
| `apikey` | → | Yes | Anon key |
| `Idempotency-Key` | → | **All mutating Edge/RPC calls** | UUID v4, generated at the moment of user action, not at send time |
| `X-Request-Id` | ↔ | Recommended | Client-generated, echoed by every layer, lands in Sentry and `audit_logs` |
| `X-App-Version` | → | Yes | Drives the force-upgrade gate |
| `X-Client-Locale` | → | Yes | `ms` \| `en` — selects the localised error message |
| `Accept-Encoding: gzip, br` | → | Yes | Non-negotiable on 3G |
| `X-Data-Saver` | → | Optional | `1` ⇒ server omits image URLs and trims page size |
| `Prefer: return=minimal` | → | On writes | Suppresses the response body when the client does not need it |

### 2.2 Errors

Every non-2xx response uses one envelope. Localisation is server-side because the client cannot be trusted to have a current string table — it may be running a build from four months ago.

```json
{
  "error": {
    "code": "CAPACITY_EXCEEDED",
    "message": "This trip no longer has room for your parcel.",
    "message_ms": "Trip ini sudah tiada ruang untuk kiriman awak.",
    "details": { "available_grams": 4200, "requested_grams": 8000 },
    "request_id": "01J8X...",
    "retriable": false
  }
}
```

| HTTP | When |
|---|---|
| 400 | Validation failure |
| 401 | Missing/expired token |
| 403 | RLS denial or role mismatch |
| 404 | Not found, or exists but invisible under RLS (deliberately indistinguishable) |
| 409 | State conflict, idempotency key reuse with a different body, capacity exhausted |
| 410 | Quote or offer expired |
| 422 | Business-rule violation (budget cap, float limit, band) |
| 426 | App version below `min_supported_version` |
| 429 | Rate limited — includes `Retry-After` |
| 5xx | Server fault; **always retriable** |

`retriable` is explicit rather than inferred, because the offline outbox needs a machine-readable answer to "should I try this again in ten minutes or surface it to the user?"

### 2.3 Error codes

```
AUTH_*         AUTH_OTP_INVALID, AUTH_OTP_LOCKED, AUTH_PHONE_BLOCKED, AUTH_SESSION_EXPIRED
QUOTE_*        QUOTE_EXPIRED, QUOTE_ALREADY_USED, QUOTE_MISMATCH
CAPACITY_*     CAPACITY_EXCEEDED, CAPACITY_HOLD_EXPIRED, TRIP_NOT_BOARDING
STATE_*        STATE_INVALID_TRANSITION, STATE_ACTOR_NOT_PERMITTED, STATE_ALREADY_APPLIED
PROOF_*        PROOF_INVALID_SIGNATURE, PROOF_NONCE_CONSUMED, PROOF_OTP_INVALID,
               PROOF_OTP_LOCKED, PROOF_EXPIRED, PROOF_GEO_OUT_OF_RANGE
BUDGET_*       BUDGET_CAP_EXCEEDED, BUDGET_VARIANCE_REQUIRED, BUDGET_VARIANCE_PENDING
FLOAT_*        FLOAT_LIMIT_EXCEEDED, COD_NOT_PERMITTED
PAYMENT_*      PAYMENT_FAILED, PAYMENT_METHOD_UNAVAILABLE, PAYMENT_ALREADY_SETTLED
VOUCHER_*      VOUCHER_EXPIRED, VOUCHER_LIMIT_REACHED, VOUCHER_BUDGET_EXHAUSTED
IDEMPOTENCY_KEY_REUSE
UPGRADE_REQUIRED
```

### 2.4 Pagination

Keyset only. `OFFSET` is banned — it degrades on exactly the tables that grow.

```
GET /rest/v1/kirim_requests?status=eq.POSTED&order=created_at.desc,id.desc&limit=20
  &or=(created_at.lt.2026-09-03T04:00:00Z,and(created_at.eq.2026-09-03T04:00:00Z,id.lt.01J8X...))
```

Edge endpoints wrap this as an opaque cursor:

```json
{ "data": [...], "next_cursor": "eyJ0IjoiMjAyNi0wOS0wM1QwNDowMDowMFoiLCJpIjoiMDFKOFgifQ", "has_more": true }
```

Default page size 20; `X-Data-Saver: 1` or `devices.total_ram_mb < 3000` reduces it to 10 server-side.

### 2.5 Field selection

Mandatory on list endpoints. A board row must not carry a full description.

```
GET /rest/v1/products?select=id,title,price_sen,weight_grams,product_images(storage_path)&limit=20
```

Response budget: **≤ 50 KB compressed** per screen (`NFR-121`). Enforced by a CI test that fetches each catalogued endpoint against seed data and fails the build on overrun.

### 2.6 Versioning

- Edge Functions: `/functions/v1/...`. A breaking change ships as `v2` alongside `v1`.
- `v1` is supported for **12 months** after `v2` ships. Rural users update slowly; some will be months behind.
- Deprecation is advertised with `Sunset` and `Deprecation` response headers, logged per app version so the ops team can see who is still on the old path.
- `app_config.min_supported_version` triggers a hard `426` gate. Reserved for security fixes and money-path corrections only — never for feature pushes.

---

## 3. Authentication

### 3.1 Phone OTP

```
POST /functions/v1/auth-otp-request
{ "phone": "+60128889999", "channel": "sms" | "whatsapp", "captcha_token": "..." }
→ 200 { "expires_in": 300, "resend_after": 30, "channel_used": "sms" }
```

Rate limits are layered because SMS pumping is a direct cash loss:

| Scope | Limit |
|---|---|
| Per phone | 5 / hour, 10 / day |
| Per IP | 20 / hour |
| Per device `install_id` | 10 / day |
| Global circuit breaker | Trips if OTP spend exceeds an hourly ceiling |

Resend backoff 30 → 60 → 120 s. After 3 requests, a Turnstile token becomes mandatory. Only `+60` numbers are accepted at launch.

```
POST /functions/v1/auth-otp-verify
{ "phone": "+60128889999", "code": "123456", "install_id": "..." }
→ 200 { "access_token": "...", "refresh_token": "...", "is_new_user": true }
→ 401 AUTH_OTP_INVALID   (attempts_remaining in details)
→ 429 AUTH_OTP_LOCKED    (5 failures ⇒ 15-minute lock)
```

### 3.2 Session

- Access token 1 h; refresh token 60 days with rotation and reuse detection.
- Tokens in `expo-secure-store` (Android Keystore).
- Refresh is proactive at 80 % of lifetime, and the client tolerates a stale token during offline periods — it queues rather than logging the user out. **Losing a session because a village lost signal is a product failure, not a security win.**

### 3.3 JWT claims

Roles are minted into the token by a custom access token hook, so RLS reads a claim instead of joining `user_roles` on every policy evaluation.

```json
{
  "sub": "01J8X...",
  "role": "authenticated",
  "app_metadata": {
    "roles": ["customer", "carrier"],
    "carrier_id": "01J8Y...",
    "seller_id": null,
    "agent_id": null,
    "account_status": "active"
  }
}
```

A role change requires a token refresh to take effect. The client force-refreshes after any verification approval.

---

## 4. Endpoint catalogue

Legend — **P** PostgREST · **R** RPC · **E** Edge Function · 🔒 idempotency key required

### 4.1 Profile, address, community

| # | Method | Endpoint | Type | Notes |
|---|---|---|---|---|
| 1 | GET | `/profiles?id=eq.{me}` | P | Own profile |
| 2 | PATCH | `/profiles?id=eq.{me}` | P | Non-privileged columns only; a trigger rejects `status`, `rating_avg`, counters |
| 3 | GET | `/profiles?id=eq.{other}&select=display_name,avatar_path,rating_avg,rating_count` | P | Public projection only |
| 4 | GET | `/user_badges?user_id=eq.{id}&select=*,badge_definitions(*)` | P | Lencana |
| 5 | GET/POST/PATCH | `/addresses` | P | Own only |
| 6 | POST | `/rpc/resolve_address_node` | R | Address → nearest `route_node`; server-side so matching keys stay consistent |
| 7 | GET | `/communities?select=id,name,district` | P | Public reference |
| 8 | POST | `/rpc/join_community` | R | Membership |
| 9 | POST | `/functions/v1/account-delete-request` | E 🔒 | Starts the anonymisation flow (FR-106) |

### 4.2 Quoting

```
POST /rest/v1/rpc/quote_kirim
{
  "kirim_type": "BELI",
  "category_id": "01J...",
  "est_weight_grams": 2000,
  "budget_cap_sen": 3500,
  "origin_node_id": "01J...",
  "dest_node_id": "01J...",
  "handling_flags": ["PERISHABLE"],
  "payment_method": "COD",
  "voucher_code": "KASIH10"
}
→ 200
{
  "quote_id": "01J...",
  "expires_at": "2026-09-03T04:15:00Z",
  "corridor_km": 248.50,
  "breakdown": {
    "goods_budget_sen": 3500,
    "base_fare_sen": 400,
    "distance_sen": 11183,
    "weight_sen": 0,
    "handling_sen": 100,
    "remoteness_multiplier_bps": 12500,
    "delivery_fee_sen": 1500,
    "discount_sen": 0
  },
  "order_total_sen": 5000,
  "commission_sen": 1250,
  "carrier_earning_sen": 250,
  "pricing_rule_version": 1
}
```

The client renders this. It holds **no coefficients and no formula** — a decompiled APK reveals nothing about pricing, and a rate change ships without a store release.

`carrier_earning_sen` is returned deliberately: FR-245 requires a carrier to see earnings *before* accepting, and hiding it would breed exactly the mistrust the product exists to solve.

### 4.3 Kirim

| # | Method | Endpoint | Type | Notes |
|---|---|---|---|---|
| 10 | POST | `/rpc/create_kirim` | R 🔒 | Requires a live `quote_id`; server re-validates and re-prices on mismatch |
| 11 | GET | `/kirim_requests?requester_id=eq.{me}` | P | Own list |
| 12 | GET | `/kirim_requests?id=eq.{id}&select=*,deliveries(*),price_variances(*)` | P | Detail |
| 13 | PATCH | `/kirim_requests?id=eq.{id}&status=eq.DRAFT` | P | Drafts only; RLS blocks everything else |
| 14 | POST | `/functions/v1/kirim-publish` | E 🔒 | `DRAFT → POSTED`; takes payment authorisation |
| 15 | POST | `/rpc/cancel_kirim` | R 🔒 | Policy-evaluated; releases capacity; posts refund |
| 16 | POST | `/rpc/repost_kirim` | R 🔒 | Clones an expired request, fresh quote |

### 4.4 Papan Kirim

```
POST /rest/v1/rpc/board_kirim_for_trip     -- carrier: what cargo fits my trip
{ "trip_id": "01J...", "limit": 20, "cursor": null }
→ {
  "data": [{
    "kirim_id": "01J...",
    "reference_code": "KK-7F3K2A",
    "item_description": "Udang galah saiz sederhana, 2kg",
    "category": "Hasil Laut",
    "kirim_type": "BELI",
    "est_weight_grams": 2000,
    "budget_cap_sen": 3500,
    "origin": "Beluran",
    "destination": "Kg Kepayan Baru",
    "pickup_date": "2026-09-04",
    "pickup_window": "pagi",
    "carrier_earning_sen": 250,
    "cod_amount_sen": 5000,
    "match_score": 87,
    "detour_km": 2.4,
    "requester": { "display_name": "Siti A.", "rating_avg": 4.8 }
  }],
  "next_cursor": "..."
}

POST /rest/v1/rpc/board_trips_for_kirim    -- requester: who is going my way
```

Both are RPC, not PostgREST, because ranking must be server-computed (FR-163) and the score must not be re-derivable client-side. Results cache in `match_results` for 5 minutes, invalidated on any capacity or state change on either side.

**Cost note.** These are the highest-traffic authenticated calls in the product. They are deliberately RPC-in-Postgres rather than Edge, so a board refresh costs one query and no function invocation.

### 4.5 Offers

| # | Method | Endpoint | Type | Notes |
|---|---|---|---|---|
| 20 | POST | `/rpc/make_offer` | R 🔒 | Carrier offers on a Kirim, or requester requests a trip slot. Places a **HELD** capacity reservation with TTL. |
| 21 | POST | `/rpc/accept_offer` | R 🔒 | Promotes `HELD → CONFIRMED`, creates the delivery, issues handover codes. All in one transaction. |
| 22 | POST | `/rpc/decline_offer` | R 🔒 | Releases the hold |
| 23 | POST | `/rpc/counter_offer` | R 🔒 | `422` if outside the ±20 % band (BR-906) |
| 24 | GET | `/delivery_offers?...` | P | Own offers |

`accept_offer` is the single most safety-critical write in the system. Its shape:

```sql
BEGIN
  SELECT ... FROM trips WHERE id = $1 FOR UPDATE;      -- serialise this trip
  -- guards: trip BOARDING, offer not expired, carrier active,
  --         handling capabilities ⊇ flags, float headroom (BR-908)
  UPDATE trip_reservations SET status='CONFIRMED' ...;  -- trigger re-checks CHECK constraints
  INSERT INTO deliveries ...;
  INSERT INTO delivery_events ...;
  PERFORM internal.fn_issue_handover_codes(delivery_id);
  PERFORM internal.fn_enqueue_notification(...);
COMMIT;
```

Every guard is inside the lock. There is no window in which two carriers can both win the last slot.

### 4.6 Trips and Kirim Balik

| # | Method | Endpoint | Type | Notes |
|---|---|---|---|---|
| 30 | POST | `/rpc/create_trip` | R 🔒 | Resolves the corridor node path server-side from origin/destination |
| 31 | POST | `/rpc/announce_return_leg` | R 🔒 | **The Kirim Balik primitive** (FR-243). Mirrors a completed trip: swaps endpoints, reverses the corridor, carries capacity and capabilities forward. One tap. |
| 32 | GET | `/trips?carrier_id=eq.{me}` | P | My trips |
| 33 | PATCH | `/trips?id=eq.{id}` | P | Pre-`DEPARTED`; a trigger rejects any write to `capacity_*` or `reserved_*` |
| 34 | POST | `/rpc/trip_transition` | R 🔒 | `ANNOUNCED → BOARDING → DEPARTED → …` |
| 35 | POST | `/rpc/cancel_trip` | R 🔒 | Releases all reservations, re-posts affected Kirim, notifies every requester |
| 36 | GET | `/functions/v1/trip-manifest?trip_id=` | E | **Full offline manifest** — stops in order, contacts, address photos, handover method, COD amounts, budget caps. Cached to SQLite on trip start. |

`trip-manifest` is an Edge Function rather than a view because it assembles signed image URLs, and because it is the one payload the app must be able to survive an entire journey on.

### 4.7 Delivery execution

All state changes go through one endpoint. There is no `PATCH /deliveries`.

```
POST /rest/v1/rpc/delivery_transition
Idempotency-Key: 01J8X...
{
  "delivery_id": "01J...",
  "event": "CONFIRM_PICKUP",
  "proof": {
    "method": "QR",
    "token": "kk1.eyJ2IjoxLC...Zg.MEUCIQD...",
    "captured_at": "2026-09-04T01:22:04Z",
    "geo": { "lat": 5.8667, "lng": 117.5333, "accuracy_m": 18, "is_mock": false }
  },
  "offline_captured": true
}
→ 200 { "status": "PICKED_UP", "proof_quality": "STRONG", "next_events": ["DEPART","REPORT_ISSUE"] }
```

| Event | Actor | Proof | Notes |
|---|---|---|---|
| `START_PROCUREMENT` | carrier | — | `BELI` only |
| `RECORD_PURCHASE` | carrier | receipt photo | Requires `actual_goods_sen`; trigger enforces the cap |
| `CONFIRM_PICKUP` | carrier / agent | QR \| OTP \| AGENT | |
| `DEPART` | carrier | — | |
| `ARRIVE_HUB` / `LEAVE_HUB` | carrier / agent | — | |
| `START_DELIVERY` | carrier | — | |
| `CONFIRM_DELIVERY` | carrier / agent | QR \| OTP \| AGENT \| PHOTO | COD amount recorded here |
| `CONFIRM_RECEIPT` | **requester/recipient** | — | **Releases escrow** (BR-907) |
| `REPORT_FAILURE` | carrier | reason + photo | |
| `CANCEL` | requester / carrier | — | Policy-evaluated |
| `ADMIN_OVERRIDE` | admin | mandatory reason | Always audited |

`next_events` is returned so the client can render valid actions without embedding a copy of the state machine that will drift from the server's.

### 4.8 Handover — QR and OTP

| # | Method | Endpoint | Type | Notes |
|---|---|---|---|---|
| 40 | GET | `/functions/v1/handover-qr?delivery_id=&leg=` | E | Returns the Ed25519-signed token for display. **Cached to SQLite immediately** — it must render with no signal. |
| 41 | POST | `/functions/v1/handover-otp-send` | E 🔒 | Sends the 6-digit code by push + SMS |
| 42 | POST | `/rpc/verify_handover` | R 🔒 | Verifies QR signature or OTP hash; consumes the nonce |
| 43 | POST | `/rpc/rotate_handover_code` | R 🔒 | After a lockout |

QR verification, server-side:

```
1. Parse kk1.<payload>.<sig>
2. Verify Ed25519 signature against the Vault public key  → PROOF_INVALID_SIGNATURE
3. Check exp                                              → PROOF_EXPIRED
4. INSERT INTO internal.handover_nonces (nonce, ...)      → PROOF_NONCE_CONSUMED on conflict
5. Assert payload.delivery_id and leg match the request
6. Assert the submitting actor is the assigned carrier/agent
7. Evaluate geo: distance to expected node
      ≤ 500 m  → STRONG
      ≤ 5 km   → STRONG, flagged
      > 5 km, or mock location, or clock skew > 30 min → SUSPECT, review queue
8. Execute the transition
```

Step 4 is the replay defence and it is a unique index, not a code path. A screenshotted QR submitted twice fails the second time regardless of which server instance handles it.

### 4.9 Price variance (Kirim Beli)

The mechanism behind *"Kalau harga pasar lebih tinggi, kita akan hubungi awak."*

```
POST /rest/v1/rpc/raise_price_variance          -- carrier, at the market
{ "kirim_id": "01J...", "market_price_sen": 4200,
  "requested_amount_sen": 4200, "evidence_photo_path": "...", "note": "Harga naik, musim hujan" }
→ 201 { "variance_id": "01J...", "expires_at": "2026-09-04T03:30:00Z" }

POST /rest/v1/rpc/respond_price_variance        -- requester
{ "variance_id": "01J...", "decision": "APPROVE" | "REDUCE_QTY" | "DECLINE",
  "approved_amount_sen": 4200 }
```

Notification ladder: push immediately → SMS after 5 minutes unacknowledged → expires at 2 h to **DECLINE**.

**The default is not to spend.** A requester who is out of coverage — the normal condition in Beluran — must never return online to find money was spent without their agreement. `APPROVE` above the original cap triggers a top-up payment, itself idempotent.

### 4.10 Marketplace

| # | Method | Endpoint | Type |
|---|---|---|---|
| 50 | GET | `/products?status=eq.active&select=...` | P |
| 51 | GET | `/rpc/search_products` | R (trigram + tsvector, ranked) |
| 52 | GET | `/products?id=eq.{id}&select=*,product_images(*),sellers(business_name,rating_avg)` | P |
| 53 | POST | `/rpc/quote_delivery_for_product` | R — quote before add-to-cart (FR-181) |
| 54 | GET/POST/DELETE | `/rpc/cart_*` | R — **server-held cart** (FR-182) |
| 55 | POST | `/functions/v1/checkout` | E 🔒 — reserves stock, splits by seller, creates payment intent |
| 56 | GET | `/orders?buyer_id=eq.{me}` | P |
| 57 | POST | `/rpc/order_transition` | R 🔒 — seller accept/reject/ready |

### 4.11 Seller

| # | Method | Endpoint | Type |
|---|---|---|---|
| 60 | POST | `/functions/v1/seller-apply` | E 🔒 |
| 61 | POST/PATCH | `/products` | P (own, RLS) |
| 62 | POST | `/functions/v1/media-upload-url` | E — signed resumable upload target |
| 63 | POST | `/rpc/adjust_inventory` | R 🔒 — writes an append-only movement |
| 64 | GET | `/rpc/seller_sales_summary` | R |

### 4.12 Payments and payouts

| # | Method | Endpoint | Type | Notes |
|---|---|---|---|---|
| 70 | POST | `/functions/v1/payment-intent` | E 🔒 | Billplz sandbox only today (P2-A). `{order_id}` → hosted-checkout URL. Idempotent: retrying an order that already has a bill returns the same URL |
| 71 | POST | `/rpc/rpc_get_payment_status` | R 🔒 | Poll fallback when the webhook is slow. Buyer-only, ownership-checked |
| 72 | **POST** | `/functions/v1/payment-webhook?provider={provider}` | E | **No auth — signature verified per provider inside the function.** Idempotent by the `internal.webhook_events` unique constraint |
| 73 | GET | `/rpc/my_earnings` | R | Available vs pending |
| 74 | POST | `/rpc/request_payout` | R 🔒 | `422` if below minimum or bank account unverified |
| 75 | GET | `/payouts?payee_id=eq.{me}` | P | |
| 76 | POST | `/rpc/record_cod_collection` | R 🔒 | At `CONFIRM_DELIVERY` |
| 77 | POST | `/functions/v1/cod-remit` | E 🔒 | Carrier remits cash; nets against payable |

Webhook handler, in order — the sequence matters:

```
1. Read the RAW body (before parsing — a re-serialised body breaks the HMAC)
2. Verify signature, constant-time compare      → 401, do not process
3. INSERT ... ON CONFLICT (provider, provider_event_id) DO NOTHING
   0 rows ⇒ already seen ⇒ 200 immediately
4. BEGIN
     SELECT ... FROM internal.payments WHERE id = $1 FOR UPDATE
     IF incoming_precedence <= current_precedence:
        mark IGNORED_OUT_OF_ORDER; COMMIT; return 200
     apply transition; fn_post_ledger(...); enqueue notifications
   COMMIT
5. 200
```

Always `200` on a verified, well-formed event. Provider retries are reserved for genuine failures, not for events we have already handled.

### 4.13 Chat, notifications, reviews, disputes

| # | Method | Endpoint | Type |
|---|---|---|---|
| 80 | GET | `/messages?conversation_id=eq.{id}` | P (+ Realtime while foregrounded) |
| 81 | POST | `/messages` | P 🔒 — deduped by `client_msg_id` |
| 82 | GET | `/notifications?read_at=is.null` | P — the authoritative inbox |
| 83 | POST | `/rpc/mark_notifications_read` | R |
| 84 | POST | `/rpc/register_device` | R — push token upsert |
| 85 | POST | `/rpc/submit_review` | R 🔒 — post-completion only; double-blind |
| 86 | POST | `/functions/v1/dispute-open` | E 🔒 — sets `holds_escrow` |
| 87 | POST | `/functions/v1/dispute-evidence` | E 🔒 |

### 4.14 Sync

```
GET /functions/v1/sync-pull?since=2026-09-03T04:00:00Z
    &tables=deliveries,kirim_requests,orders,notifications,price_variances&limit=200
→ {
  "changes": { "deliveries": [...], "kirim_requests": [...] },
  "cursor": "2026-09-03T06:12:44.918Z",
  "has_more": false,
  "server_time": "2026-09-03T06:12:45.002Z",
  "clock_skew_ms": 4120
}
```

`server_time` and `clock_skew_ms` matter: the client uses them to correct offline-captured timestamps rather than trusting a device clock that may be wrong by hours.

Scope is always the caller's own data, enforced by RLS — `sync-pull` is not a privileged endpoint. Page size is capped so a device offline for two weeks recovers incrementally instead of demanding one enormous response over 3G.

```
POST /functions/v1/sync-push
{ "mutations": [ { "id": "...", "endpoint": "rpc/delivery_transition",
                   "idempotency_key": "...", "payload": {...} } ] }
→ { "results": [ { "id": "...", "status": "applied" | "duplicate" | "conflict" | "failed",
                   "error": {...}, "server_state": {...} } ] }
```

Batched to amortise TLS setup on a bad link. Each mutation is applied independently; one failure does not roll back the batch. `conflict` returns `server_state` so the client can reconcile and tell the user what actually happened — *"Kiriman ini telah dibatalkan semasa anda di luar talian."*

### 4.15 Config and gating

```
GET /functions/v1/app-config
→ {
  "min_supported_version": "1.4.0",
  "latest_version": "1.9.2",
  "force_upgrade": false,
  "feature_flags": { "marketplace": true, "prepaid_payments": false, "agent_hubs": false },
  "payment_methods_enabled": ["COD", "FPX", "DUITNOW_QR"],
  "max_budget_cap_sen": 25000,
  "settlement_window_hours": 48,
  "maintenance": null
}
```

Fetched on cold start with a **500 ms timeout** and a cached fallback. Config must never be able to prevent the app from opening — a config outage in Beluran cannot be allowed to look like a broken app.

`payment_methods_enabled` is the kill switch: if the gateway degrades, prepaid methods disappear and COD carries the network (`ARCHITECTURE.md` §16).

### 4.16 Admin

Server-side only, from Next.js Server Actions using `service_role`. Never reachable from the mobile app.

| Area | Endpoints |
|---|---|
| Users | list, detail, suspend, restore, grant/revoke role |
| Verification | queue, document view (audited), approve/reject, set tier |
| Deliveries | inspect, full event timeline, `ADMIN_OVERRIDE` transition |
| Payments | inspect, **replay webhook**, manual reconcile |
| Payouts | review → approve (maker/checker) → batch → mark paid |
| Disputes | workspace, evidence, resolve with refund posting |
| Route graph | node/edge CRUD, rebuild distance matrix |
| Pricing | new `pricing_rules` version, preview against historical quotes |
| Vouchers | campaign CRUD, budget monitor, kill switch |
| Fraud | risk queue, block/allow/escalate |
| Analytics | GMV, fill rate, match rate, COD exposure, voucher burn |

Every mutation writes `audit.audit_logs` **in the same transaction** as the change. An action whose audit write fails does not commit.

---

## 5. Rate limits

| Endpoint class | Limit | Rationale |
|---|---|---|
| OTP request | 5/h per phone | Direct SMS cost |
| Auth verify | 10/h per phone | Brute force |
| Handover verify | 10/h per delivery | OTP guessing |
| Board queries | 60/min per user | Pull-to-refresh abuse |
| Quote | 30/min per user | Compute cost |
| Mutations (general) | 120/min per user | |
| `sync-push` | 20/min per device | Batched anyway |
| Media upload URL | 60/h per user | Storage abuse |
| Webhooks | 1000/min per provider | Provider bursts |

Limits are enforced at the Edge with a Postgres-backed counter and return `429` with `Retry-After`. The client's outbox honours `Retry-After` exactly rather than applying its own backoff — otherwise a village coming back online produces a synchronised retry storm.

---

## 6. Payload budgets

| Screen | Budget (gzip) | Technique |
|---|---|---|
| Papan Kirim page (20 rows) | 18 KB | Field selection, no descriptions, thumb URLs only |
| Kirim detail | 8 KB | |
| Trip manifest (10 stops) | 35 KB | Signed URLs, no inline images |
| Product list (20) | 22 KB | `w=160` thumbnails |
| Order history (20) | 12 KB | |
| Sync pull (200 changes) | 45 KB | |
| `app-config` | 2 KB | |

Verified by an automated test per endpoint (`TESTING.md`). Exceeding a budget fails CI — payload size is treated as a correctness property, not a performance nicety, because the user is paying for every kilobyte on prepaid data.

---

## 7. Idempotency contract

```
Client:  key generated when the USER ACTS  (not when the request is sent)
         stored in the SQLite outbox alongside the payload
         reused on every retry, for as long as the item lives in the queue

Server:  internal.idempotency_keys (key, actor, endpoint, request_hash, response, expires_at)

         same key + same request_hash  → replay the stored response (200/201)
         same key + different hash     → 409 IDEMPOTENCY_KEY_REUSE
         unknown key                   → process, then store
         TTL 24 h
```

The birth-time rule is what makes offline safe. A carrier confirms a delivery in a valley with no signal; the item sits in the outbox for two days; it is retried eleven times as the phone drifts in and out of coverage. All eleven carry the same key, so exactly one transition and one ledger posting occur.

---

## 8. Realtime channels

| Channel | Subscription | Lifetime |
|---|---|---|
| `chat:{conversation_id}` | Postgres Changes on `messages`, RLS-filtered | While the chat screen is open |
| `delivery:{delivery_id}` | Changes on `deliveries` | While the tracking screen is **foregrounded** |
| `admin:queues` | Changes on disputes, verifications | Admin session |

Not realtime: board updates (pull-to-refresh + push), carrier location (30–60 s polling). Subscriptions are torn down on background and re-established with backoff on foreground. On an unstable network, reconnection storms cost real money in data and battery — realtime is used where it earns its keep and nowhere else.
