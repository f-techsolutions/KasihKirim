# KasihKirim — Security Design

Authorisation model for the schema in [`DATABASE.md`](./DATABASE.md) and the endpoints in [`API.md`](./API.md).

---

## 1. Security principles

1. **Default deny.** RLS on every table. No policy means no access. A new table is unreachable until someone writes a policy and a test for it.
2. **Schema separation before RLS.** Money lives in `internal`, which PostgREST cannot address at all. A forgotten policy there is inert rather than catastrophic.
3. **The client is hostile.** Assume the APK is decompiled, the JWT is forged, the device is rooted, and every request is replayed. Nothing in the app is a control.
4. **Invariants in the database.** A constraint that cannot be bypassed beats a check that can be forgotten.
5. **Least privilege, including for admins.** No single account can both move money and grant itself permissions.
6. **Everything privileged is audited**, in the same transaction as the action.
7. **Collect the minimum.** Data not held cannot be leaked. Location history is 30 days; NRIC is stored as an HMAC.

---

## 2. Threat model

| # | Threat | Impact | Control |
|---|---|---|---|
| T-01 | User forges a lower price at checkout | Direct loss | Server-issued quotes; client sends `quote_id`, never amounts (`API.md` §4.2) |
| T-02 | User edits their own payout/ledger row | Direct loss | Ledger in `internal`; `UPDATE`/`DELETE` revoked from every role incl. `service_role` |
| T-03 | Replayed payment webhook credits twice | Direct loss | `ux_webhook_idem` unique constraint; insert-first-then-process |
| T-04 | Replayed QR closes a delivery twice | Fraud, double payout | Single-use nonce unique index; idempotency keys |
| T-05 | Carrier marks delivered without delivering | Fraud, chargeback | Proof ladder; geofence; `proof_quality`; settlement hold on `WEAK`/`SUSPECT` |
| T-06 | Two carriers accept the last capacity slot | Physical failure | `FOR UPDATE` lock + `CHECK` constraint + TTL holds |
| T-07 | Carrier inflates goods cost on `BELI` | Direct loss to requester | Budget cap trigger; mandatory receipt photo; rolling median comparison; variance approval required |
| T-08 | Requester and carrier collude on fake variances | Loss, voucher farming | Pair-frequency risk signal; approval-rate monitoring; device/bank overlap detection |
| T-09 | SMS pumping via OTP endpoint | Direct cash loss | Layered rate limits, Turnstile after 3, `+60` allowlist, global spend circuit breaker |
| T-10 | Enumeration of other users' deliveries | Privacy breach | RLS scoped to counterparties; 404 for both missing and forbidden |
| T-11 | KYC document exfiltration | Serious privacy breach, PDPA | Private bucket, 15-min signed URLs, compliance role only, every access audited |
| T-12 | GPS spoofing to fake a delivery location | Fraud | `isFromMockProvider` recorded; skew and distance checks; `SUSPECT` flag |
| T-13 | Multi-accounting for voucher abuse | Marketing loss | Device fingerprint, phone, bank account and address-cluster reuse detection |
| T-14 | Admin account compromise | Total | Mandatory TOTP, short sessions, role segregation, audit, re-auth on destructive actions |
| T-15 | `service_role` key leaked from admin console | Total | Server-only usage; never in a client bundle; scanned in CI; rotation runbook |
| T-16 | Off-platform payment solicitation in chat | Escrow bypass, user harm | Pattern flagging, report flow, escrow-only settlement policy |
| T-17 | Malicious payload in offline outbox replay | State corruption | Server-side validation on every replay; keys bound to actor and endpoint |
| T-18 | Prohibited goods carried via `BELI` | Legal, safety | Category and keyword blocklist at Kirim creation; carrier refusal path; reporting |
| T-19 | Stolen device with an active session | Account takeover | Refresh rotation with reuse detection; remote device revoke; re-auth for payouts |
| T-20 | Rooted device tampering with local SQLite | Limited — cache only | No authoritative state client-side; server revalidates every replayed mutation |

---

## 3. Authentication

### 3.1 Phone OTP hardening

| Control | Setting |
|---|---|
| Code | 6 digits, CSPRNG |
| TTL | 5 minutes |
| Attempts | 5, then 15-minute lock |
| Storage | HMAC-SHA256 with Vault pepper — never plaintext |
| Comparison | Constant-time |
| Resend backoff | 30 → 60 → 120 s |
| CAPTCHA | Turnstile required after 3 requests |
| Country | `+60` only at launch |
| Circuit breaker | Hourly SMS spend ceiling; trips to WhatsApp-only |

At RM 12.50 revenue per order, an SMS pumping attack is not just an abuse problem — it is a direct assault on the margin. The spend ceiling is a financial control as much as a security one.

### 3.2 Sessions

- Access token 1 h; refresh 60 days, **rotation on, reuse detection on**.
- Reuse of a rotated refresh token revokes the entire family and raises a risk signal.
- Storage: `expo-secure-store` (Android Keystore). Never `AsyncStorage`, never plain files.
- **Offline tolerance:** an expired access token during an offline period queues work rather than forcing logout. Signing a user out because their village lost signal is a product failure.
- Re-authentication (fresh OTP) is required for: payout request, bank account change, phone change, account deletion.

### 3.3 Role claims

```sql
CREATE OR REPLACE FUNCTION auth.custom_access_token_hook(event jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_roles text[]; v_meta jsonb;
BEGIN
  SELECT array_agg(role::text) INTO v_roles
  FROM public.user_roles
  WHERE user_id = (event->>'user_id')::uuid AND revoked_at IS NULL;

  SELECT jsonb_build_object(
    'roles', COALESCE(to_jsonb(v_roles), '[]'::jsonb),
    'carrier_id', (SELECT id FROM public.carriers WHERE user_id=(event->>'user_id')::uuid
                     AND status='APPROVED'),
    'seller_id',  (SELECT id FROM public.sellers  WHERE user_id=(event->>'user_id')::uuid
                     AND status='APPROVED'),
    'account_status', (SELECT status FROM public.profiles WHERE id=(event->>'user_id')::uuid)
  ) INTO v_meta;

  RETURN jsonb_set(event, '{claims,app_metadata}',
                   COALESCE(event->'claims'->'app_metadata','{}'::jsonb) || v_meta);
END $$;
```

Putting roles in the claim rather than joining `user_roles` in every policy is the difference between a fast board query and a slow one. `carrier_id` in the claim means carrier-scoped policies are a direct comparison, not a subquery.

**Trade-off:** a suspension does not bite until the token refreshes (≤ 1 h). For immediate effect, `account_status` is re-checked inside every money-path RPC, so a suspended user cannot transact even with a valid token.

---

## 4. RLS

### 4.1 Helper functions

```sql
CREATE OR REPLACE FUNCTION auth.user_roles() RETURNS text[]
LANGUAGE sql STABLE AS $$
  SELECT COALESCE(
    ARRAY(SELECT jsonb_array_elements_text(
      NULLIF(current_setting('request.jwt.claims', true), '')::jsonb
        -> 'app_metadata' -> 'roles')), '{}');
$$;

CREATE OR REPLACE FUNCTION auth.has_role(p text) RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT p = ANY(auth.user_roles()); $$;

CREATE OR REPLACE FUNCTION auth.is_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM unnest(auth.user_roles()) r WHERE r LIKE 'admin_%');
$$;

CREATE OR REPLACE FUNCTION auth.my_carrier_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('request.jwt.claims', true)::jsonb
    -> 'app_metadata' ->> 'carrier_id','')::uuid;
$$;
```

All are `STABLE`, so the planner evaluates them once per statement instead of once per row.

### 4.2 The `(SELECT auth.uid())` rule

```sql
-- SLOW: re-evaluated per row
USING (user_id = auth.uid())

-- FAST: evaluated once, treated as a constant by the planner
USING (user_id = (SELECT auth.uid()))
```

**Mandatory in every policy.** On a table of any size the difference is a sequential scan versus an index seek. Enforced by a lint rule in CI.

### 4.3 Representative policies

```sql
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY profiles_select_own ON public.profiles
  FOR SELECT TO authenticated
  USING (id = (SELECT auth.uid()) OR auth.is_admin());

-- Counterparties see a limited projection via a view, not this table.
CREATE POLICY profiles_update_own ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = (SELECT auth.uid()))
  WITH CHECK (id = (SELECT auth.uid()));
-- No INSERT policy: profiles are created by a trigger on auth.users.
-- No DELETE policy: deletion is anonymisation only (DATABASE.md §16.2).
```

Column protection, because an `UPDATE` policy alone cannot stop a user editing their own rating:

```sql
CREATE OR REPLACE FUNCTION internal.tg_protect_profile_columns()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF auth.is_admin() THEN RETURN NEW; END IF;
  NEW.status               := OLD.status;
  NEW.rating_avg           := OLD.rating_avg;
  NEW.rating_count         := OLD.rating_count;
  NEW.kirim_sent_count     := OLD.kirim_sent_count;
  NEW.kirim_received_count := OLD.kirim_received_count;
  NEW.phone                := OLD.phone;   -- changed only via the verified flow
  NEW.nric_hash            := OLD.nric_hash;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_profiles_protect BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION internal.tg_protect_profile_columns();
```

**Kirim — board visibility without leaking contact details:**

```sql
ALTER TABLE public.kirim_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY kirim_select ON public.kirim_requests
  FOR SELECT TO authenticated
  USING (
    requester_id = (SELECT auth.uid())
    OR (status = 'POSTED' AND visibility = 'board' AND deleted_at IS NULL
        AND auth.has_role('carrier'))
    OR EXISTS (SELECT 1 FROM public.deliveries d
               WHERE d.kirim_id = kirim_requests.id
                 AND d.carrier_id = auth.my_carrier_id())
    OR auth.is_admin()
  );

CREATE POLICY kirim_insert ON public.kirim_requests
  FOR INSERT TO authenticated
  WITH CHECK (requester_id = (SELECT auth.uid()) AND status = 'DRAFT');

CREATE POLICY kirim_update_draft ON public.kirim_requests
  FOR UPDATE TO authenticated
  USING (requester_id = (SELECT auth.uid()) AND status = 'DRAFT')
  WITH CHECK (requester_id = (SELECT auth.uid()) AND status = 'DRAFT');
```

A carrier browsing the board sees the request but **not** the requester's phone or exact address. Those appear only after `MATCHED`, delivered through the manifest endpoint. This is the difference between a marketplace and a scraped contact list — and it is the specific failure of the WhatsApp status economy the product exists to replace.

**Deliveries — the state machine's enforcement point:**

```sql
ALTER TABLE public.deliveries ENABLE ROW LEVEL SECURITY;

CREATE POLICY deliveries_select ON public.deliveries
  FOR SELECT TO authenticated
  USING (
    carrier_id = auth.my_carrier_id()
    OR EXISTS (SELECT 1 FROM public.kirim_requests k
               WHERE k.id = deliveries.kirim_id AND k.requester_id = (SELECT auth.uid()))
    OR auth.is_admin()
  );

-- NO INSERT, UPDATE OR DELETE POLICY EXISTS.  BR-904.
REVOKE INSERT, UPDATE, DELETE ON public.deliveries FROM authenticated, anon;
```

Both belt and braces: no policy (so RLS denies) *and* no grant (so the privilege does not exist). Either alone would suffice; together, a future migration that accidentally adds a permissive policy still cannot open a write path.

**Financial tables:**

```sql
-- internal.* is not in the PostgREST exposed schema list, so none of this is
-- reachable by a client JWT. These grants are the second and third layers.
REVOKE ALL ON ALL TABLES IN SCHEMA internal FROM anon, authenticated;
REVOKE UPDATE, DELETE ON internal.ledger_entries      FROM PUBLIC;
REVOKE UPDATE, DELETE ON internal.ledger_transactions FROM PUBLIC;
REVOKE UPDATE, DELETE ON audit.audit_logs             FROM PUBLIC;
```

Even `service_role` cannot mutate a posted ledger entry. Corrections are reversing transactions, so history is never rewritten — which is also what makes the daily reconciliation meaningful.

### 4.4 Policy checklist (CI-enforced)

Every new table must satisfy all of these or the build fails:

- [ ] `ENABLE ROW LEVEL SECURITY` present
- [ ] `FORCE ROW LEVEL SECURITY` on financial tables
- [ ] Every policy uses `(SELECT auth.uid())`, not bare `auth.uid()`
- [ ] Every column referenced in a policy is indexed
- [ ] Explicit `TO authenticated` / `TO anon` — never an implicit `PUBLIC`
- [ ] `WITH CHECK` present on every `INSERT`/`UPDATE` policy
- [ ] Absent policies are intentional and documented in the write-access matrix
- [ ] A pgTAP test exists asserting both allow and deny for every role

---

## 5. Storage

| Bucket | Public | Signed URL TTL | Write | Read |
|---|---|---|---|---|
| `product-images` | ✅ | — | Owning seller | Anyone |
| `avatars` | ✅ | — | Owner | Anyone |
| `address-photos` | ❌ | 1 h | Owner | Delivery counterparties |
| `pod` | ❌ | 1 h | Assigned carrier/agent | Counterparties + admin |
| `receipts` | ❌ | 1 h | Assigned carrier | Requester + admin |
| `kyc` | ❌ | **15 min** | Owner | **`admin_compliance` only, audited** |
| `dispute-evidence` | ❌ | 1 h | Dispute parties | Parties + admin |
| `chat-media` | ❌ | 1 h | Participants | Participants |

```sql
CREATE POLICY kyc_insert_own ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'kyc'
    AND (storage.foldername(name))[1] = (SELECT auth.uid())::text
  );

CREATE POLICY kyc_select_compliance ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'kyc' AND auth.has_role('admin_compliance'));
```

Upload limits: 5 MB per object, MIME allowlist (`image/jpeg`, `image/png`, `image/webp`, `application/pdf` for KYC only). Magic-byte validation server-side — extension and declared MIME are both attacker-controlled. EXIF is stripped from public images, **retained** on POD and receipts because it is evidence.

Every read of a `kyc` object writes an `audit.audit_logs` row naming the admin, the subject and the reason. Looking at someone's MyKad is an event, not a page view.

---

## 6. Payment integrity

### 6.1 The non-negotiables

| Control | Implementation |
|---|---|
| Client never sends amounts | Requests carry `quote_id`; server reads the amount from `internal.quotes` |
| Quotes expire | 15-minute TTL, single use, `consumed_at` set on use |
| Pricing is unreachable | `pricing_rules` in `internal`; coefficients never shipped to the client |
| Webhooks verified | HMAC over the **raw** body, constant-time compare, before parsing |
| Webhooks idempotent | Unique `(provider, provider_event_id)`; insert first, then process |
| Out-of-order safe | `status_precedence` guard under a row lock |
| Ledger balanced | Deferred constraint trigger; unbalanced transactions cannot commit |
| Ledger immutable | `UPDATE`/`DELETE` revoked from everyone |
| No card data | Hosted checkout / redirect only — PCI SAQ-A, not SAQ-D |
| Payout segregation | `approved_by <> reviewed_by` above threshold, enforced by constraint |
| Daily proof | Reconciliation job asserts Σdebits = Σcredits; any variance pages on-call and **halts payout batches** |

### 6.2 `BELI`-specific controls

The procurement flow is the most attackable surface in the product, because a carrier is spending someone else's money out of sight.

| Risk | Control |
|---|---|
| Inflated goods cost | Budget cap trigger (BR-913); receipt photo mandatory with EXIF and geo |
| Systematic overcharging | `actual_goods_sen` compared to a rolling median per category × corridor; outliers beyond 2σ raise a risk signal |
| Fake variance approvals | Approval must come from the requester's authenticated session; variance approval rate tracked per carrier and per requester↔carrier pair |
| Collusion | Repeat pairing frequency, shared device fingerprint, shared bank account, address clustering |
| Carrier absconding with the advance | Float limit (`ck_carrier_exposure`) caps total exposure; tiered by verification level and history |
| Unspent budget quietly kept | Settlement invariant `goods_escrow = actual_cost + refund`, asserted in `fn_settle_delivery` and re-asserted by the nightly reconciliation |

The last one deserves emphasis. It would be easy to build a system where a few sen of unspent budget silently accretes to the platform. Making it a settlement invariant means that outcome is not a policy decision anyone can quietly reverse — it is arithmetic the ledger refuses to violate.

### 6.3 COD and cash

- Float limit shared with procurement advances — one `CHECK` constraint covers both.
- Remittance SLA with automatic suspension on breach.
- Ageing report; shortfalls post to `WRITE_OFF` with a mandatory admin reason.
- Agent hub remittance requires dual confirmation (carrier submits, agent confirms).

---

## 7. Handover integrity

| Control | Detail |
|---|---|
| QR signing | Ed25519, private key in Supabase Vault, **never** on a device |
| QR replay | Single-use nonce, unique index — first use wins |
| QR expiry | Bound to the delivery leg, not a wall-clock window |
| OTP storage | HMAC-SHA256 with Vault pepper; a database dump yields no working codes |
| OTP brute force | 5 attempts, lock, rotate-only recovery, per-delivery rate limit |
| Geofence | Distance to expected node: ≤ 500 m `STRONG`; ≤ 5 km flagged; beyond `SUSPECT` |
| Mock location | Android `isFromMockProvider` recorded and treated as `SUSPECT` |
| Clock skew | `client_captured_at` vs `server_received_at`; > 30 min flagged |
| Weak proof | Photo-only sets `proof_quality='WEAK'`, extends settlement, queues review |

**Deliberate design choice:** a suspicious proof **flags** rather than blocks. Rural GPS is genuinely unreliable — dense canopy, valley terrain, cheap chipsets. Blocking on a geofence miss would punish honest carriers far more often than it would catch fraud. The system slows the money instead of stopping the parcel.

---

## 8. Fraud and risk

### 8.1 Signals

| Signal | Severity | Trigger |
|---|---|---|
| `MOCK_LOCATION_DETECTED` | 5 | Mock provider flag on any proof |
| `QR_REPLAY_ATTEMPT` | 5 | Nonce conflict |
| `SELF_DEALING` | 5 | Requester and carrier share device, bank account, or phone |
| `BUDGET_OUTLIER` | 4 | Goods cost > 2σ above category × corridor median |
| `VARIANCE_ABUSE` | 4 | Carrier variance rate > 3× peer median |
| `FLOAT_BREACH_ATTEMPT` | 4 | Rejected by `ck_carrier_exposure` |
| `RAPID_MULTI_ACCOUNT` | 4 | ≥ 3 accounts on one `install_id` in 7 days |
| `VOUCHER_FARMING` | 3 | Voucher redemptions clustered on a device or address |
| `PROOF_QUALITY_WEAK_STREAK` | 3 | ≥ 3 consecutive photo-only proofs |
| `CANCELLATION_SPIKE` | 3 | Carrier cancel rate > 20 % over 10 deliveries |
| `CHAT_OFFPLATFORM` | 2 | Payment-solicitation patterns in messages |
| `GEO_MISMATCH` | 2 | Proof > 5 km from expected node |

Signals accumulate into a score per subject. Thresholds drive: review queue → payout hold → suspension. All actions are reversible and audited; none are automatic bans, because a false positive in a village with one carrier removes the service entirely.

### 8.2 Prohibited goods

`BELI` lets a requester ask a carrier to buy anything. Controls: category and keyword blocklist at Kirim creation (controlled substances, weapons, wildlife under the Sabah Wildlife Conservation Enactment, age-restricted goods), a one-tap carrier refusal path with no rating penalty, and a reporting flow. Blocklist terms are data, updatable without a release.

---

## 9. Admin security

| Control | Setting |
|---|---|
| Auth | Email + password + **mandatory TOTP** |
| Session | 8 h, re-auth for destructive actions |
| `service_role` key | Server-side only; never in a client bundle; secret-scanned in CI |
| Preview deployments | Vercel protection on; staging Supabase only, never production |
| Audit | Every mutation, same transaction, append-only |
| IP allowlist | Optional per environment |

### 9.1 Role segregation

| Role | Can | Cannot |
|---|---|---|
| `admin_support` | View users, deliveries; message; open disputes | Move money; change verification |
| `admin_ops` | Verification, delivery override, route graph | Approve payouts; issue refunds |
| `admin_finance` | Payouts, refunds, reconciliation, pricing | Grant roles; view KYC documents |
| `admin_compliance` | KYC documents, fraud queue, data requests | Move money; override deliveries |
| `admin_super` | Grant and revoke roles | **Move money, approve payouts, or view KYC** |

`admin_super` is deliberately *not* a superset. The account that can grant permissions cannot use them. A single compromised admin session cannot both escalate itself and drain the payout queue — it takes two compromised accounts of different types, which is the point.

---

## 10. Mobile application security

| Control | Implementation |
|---|---|
| Token storage | `expo-secure-store` (Android Keystore). Never `AsyncStorage`. |
| Local database | Cache only. No authoritative state, no secrets, no ledger. |
| Secrets in bundle | **None.** Anon key only — it is public by design and useless without a valid JWT. |
| Code protection | R8 with obfuscation; Hermes bytecode; source maps uploaded to Sentry, not shipped |
| Network | HTTPS only; `cleartextTrafficPermitted=false`; certificate pinning **rejected** — see below |
| Rooted devices | Detected and recorded as a risk signal; **not blocked** |
| Screenshots | `FLAG_SECURE` on KYC capture, handover QR, and payout screens |
| Clipboard | OTP fields are `secureTextEntry`-adjacent and not auto-copied |
| Deep links | Validated and authorised server-side; no trust in link parameters |
| Dependencies | `npm audit` + Dependabot in CI; a critical advisory fails the build |

**Two deliberate omissions, both reasoned:**

*No certificate pinning.* Pinning breaks silently when a certificate rotates, and the failure mode is a total outage for users who cannot easily update — exactly the rural user this product serves. Supabase-managed TLS plus Android's network security config is the better trade.

*No root blocking.* Budget Android devices in this market are frequently rooted by their owners or shipped with modified ROMs. Blocking them excludes real customers. The device is untrusted anyway; the server validates everything.

---

## 11. Privacy (PDPA 2010)

| Principle | Implementation |
|---|---|
| **Notice & Choice** | Privacy notice in Bahasa Malaysia and English, shown before first data collection, versioned with consent recorded |
| **Disclosure** | Counterparty contact details revealed only after `MATCHED`, only to the counterparty, only for that delivery |
| **Security** | TLS in transit; encryption at rest; NRIC as HMAC only; bank accounts encrypted via Vault |
| **Retention** | Per class (`DATABASE.md` §16.1); location 30 days; automated pruning |
| **Data Integrity** | Users can view and correct their own data |
| **Access** | Export endpoint returning the user's own data in a machine-readable form |

### 11.1 Data minimisation decisions

- **NRIC** is never stored in plaintext — HMAC plus last four digits only. Verification compares hashes.
- **Location tracking** runs only during an active trip, via a foreground service with a visible notification, and is pruned at 30 days.
- **Full phone numbers** are masked (`+6012***9999`) everywhere except the active counterparty view and admin.
- **Chat** closes N days after delivery completion; media is purged with it.
- **Logs** never contain phone numbers, NRIC, exact coordinates, or tokens. Enforced by a Sentry `beforeSend` scrubber and a server-side log filter.

### 11.2 Account deletion

Play policy requires deletion; Malaysian tax law requires seven-year retention of financial records. Both are met by pseudonymisation (`DATABASE.md` §16.2): personal identifiers are destroyed, financial records survive pointing at an anonymised subject.

The user-facing copy must say this plainly rather than implying total erasure. Both an in-app path and a public web URL are required.

---

## 12. Incident response

| Severity | Example | Response | Target |
|---|---|---|---|
| **SEV-1** | Ledger imbalance; payment or KYC data breach | Page on-call; **halt payouts**; freeze settlement; preserve evidence | 15 min |
| **SEV-2** | Auth bypass; RLS leak; gateway compromise | Page; patch or feature-flag off; assess exposure | 1 h |
| **SEV-3** | Fraud ring; abuse spike | Ops triage; targeted suspensions | 4 h |
| **SEV-4** | Single-account compromise | Support; revoke sessions; reset | 24 h |

**Ledger imbalance is SEV-1 by definition.** It means either a bug in money handling or an intrusion, and both require the same first action: stop moving money until the cause is known.

Breach notification: assess within 24 h, notify affected users and the relevant authority per PDPA guidance and legal advice.

### 12.1 Key rotation

| Secret | Cadence | On compromise |
|---|---|---|
| Ed25519 QR key | 12 months | Rotate; support both keys for one delivery cycle; invalidate outstanding tokens |
| OTP pepper | 12 months | Rotate; invalidate all live codes |
| `service_role` key | 6 months | Immediate; redeploy admin and Edge Functions |
| Gateway webhook secret | Per provider policy | Immediate; coordinate with provider |
| Push credentials | 12 months | Re-upload to EAS |

QR key rotation supports two active keys simultaneously, because a carrier may be holding a token generated before the rotation and be out of coverage until after it. Invalidating those tokens would strand parcels.

---

## 13. Pre-launch security checklist

- [ ] RLS enabled and tested on every table; deny cases asserted, not just allow
- [ ] `internal` and `audit` absent from the PostgREST exposed schema list
- [ ] No `service_role` key in any client bundle (CI secret scan green)
- [ ] Webhook signature verification tested against tampered and replayed fixtures
- [ ] Idempotency verified under concurrent duplicate submission
- [ ] Overbooking test: N parallel bookings consume exactly capacity, no more
- [ ] Budget-cap bypass attempted and blocked
- [ ] QR replay attempted and blocked
- [ ] OTP brute force rate-limited and locked
- [ ] KYC bucket unreachable without the compliance role; access audited
- [ ] Ledger imbalance simulated; reconciliation alerts and halts payouts
- [ ] Payout maker/checker enforced by constraint, not just UI
- [ ] Admin MFA mandatory; role segregation verified by test
- [ ] Privacy notice published in BM and English
- [ ] Account deletion works in-app and on the web
- [ ] Play Data Safety form matches what the app actually collects
- [ ] Third-party penetration test completed and findings closed
