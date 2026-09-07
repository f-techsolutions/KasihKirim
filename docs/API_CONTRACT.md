# API Contract — what the Android client may call

Extracted from `supabase/migrations/`. **This file is the allow-list.** If a
call is not here, it does not exist: do not invent an RPC because the name
sounds plausible (§29).

Verified against migrations `0000`–`0011` at commit `a9eacbc`.

## 1. RPCs callable by `authenticated`

Seven, and only seven. Each is `SECURITY DEFINER SET search_path=''`, returns
`jsonb`, and has `EXECUTE` revoked from `PUBLIC` and `anon`.

| RPC | Parameters | Defined in |
|---|---|---|
| `rpc_quote_kirim` | `p_kirim_type TEXT, p_category_slug TEXT, p_est_weight_grams INT, p_origin_node UUID, p_dest_node UUID, p_budget_cap_sen BIGINT=0, p_volume_cm3 INT=8000, p_handling_flags TEXT[]='{}', p_payment_method TEXT='COD'` | `0005` |
| `rpc_accept_offer` | `p_trip UUID, p_kirim UUID, p_idempotency_key TEXT=NULL` | `0005`, reissued `0009` |
| `rpc_delivery_transition` | `p_delivery UUID, p_event TEXT, p_idempotency_key TEXT=NULL, p_meta JSONB='{}'` | `0005` |
| `rpc_check_serviceability` | `p_origin_node UUID, p_dest_node UUID` | `0008`, body `0011` |
| `rpc_my_earnings` | none | `0005` |
| `rpc_send_capacity_invite` | `p_trip UUID, p_audience TEXT, p_community UUID, p_target UUID, p_message TEXT` | `0006` |
| `rpc_buy_from_lot` | `p_lot UUID, p_qty NUMERIC, p_idempotency_key TEXT` | `0006` |

## 2. Forbidden — `service_role` only

`rpc_apply_payment_event` · `rpc_record_webhook` · `rpc_idem_lookup` ·
`rpc_idem_store` · `rpc_consume_nonce` · `rpc_risk_signal` · `rpc_reconcile` ·
`custom_access_token_hook`

These belong to Edge Functions. A `service_role` key must never exist in the
APK — it bypasses RLS on every table. The CI workflow greps for it and fails the
build.

## 3. Serviceability response

`rpc_check_serviceability` returns exactly one of five shapes. Modelled as
`domain/model/Serviceability.kt`; **do not collapse them** into one error.

| `reason` | Meaning | UI |
|---|---|---|
| *(absent, `serviceable:true`)* | Known, active, routable | Proceed. `requires_water_transport` may be true |
| `DESTINATION_NOT_ACTIVE` | Known district, not yet open | "Kami belum sampai ke {district}" |
| `ORIGIN_NOT_ACTIVE` | Same, origin side | Offer a different origin |
| `NO_ROUTE` | Both open, graph does not connect them | "Tiada laluan" |
| `GEOGRAPHY_UNKNOWN` | Genuinely unmapped input — **only** this case | "Lokasi tidak dikenali" |

## 4. Money

`BIGINT` sen. `internal` is **not** PostgREST-exposed; `internal.ledger_entries`
has `UPDATE`/`DELETE` revoked from every role including `service_role`. The
client cannot mutate money even if it tried. It displays `rpc_my_earnings` and
the quote breakdown. `domain/model/Sen.kt` wraps `Long` and offers no multiply.

## 5. Enums

`KirimStatus` (20), `TransportMode` (7, `BOAT` included), `UserRole` (9) mirror
`ref.kirim_status`, `ref.vehicle_type`, `ref.user_role`.
`BackendEnumContractTest` fails if the counts drift.

There is **no `ACCEPTED` status**. `POSTED` → `MATCHED`. `BELI` passes through
`PROCURING` before pickup.

## 6. JWT claims

`app_metadata` carries `roles[]`, `carrier_id`, `seller_id`, `account_status`,
written by `public.custom_access_token_hook`. Used for **navigation only** —
authorization is RLS.

## 7. Table reads

`0010_client_privileges.sql` grants `authenticated` exactly the privileges for
which an RLS policy already exists — 48 tables, derived from the policies rather
than chosen by hand. RLS still filters rows. `anon` has `REVOKE ALL` on `public`.
