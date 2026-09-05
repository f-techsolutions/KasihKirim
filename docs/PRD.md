# KasihKirim — Product Requirements Document

| Field | Value |
|---|---|
| Product | KasihKirim |
| Platform | **Android only** (Expo / React Native) + Next.js admin console (web) |
| Primary market | **Sabah-wide, Malaysia** (all 27 districts; rural-first design) |
| Initial pilot | Beluran, Paitan, Kota Kinabalu — operational scope only, not product scope |
| Currency | MYR (stored as integer `sen`) |
| Primary locale | `ms-MY` (Bahasa Malaysia) — default; `en-MY` secondary |
| Timezone | Asia/Kuching (UTC+8) — all storage in UTC |
| Document version | 1.0 (architecture baseline) |
| Status | For review — see §2 before implementation |

---

## 1. Purpose of this document

This PRD is the product contract that `ARCHITECTURE.md`, `DATABASE.md`, `API.md`, `SECURITY.md`, `TESTING.md`, `DEPLOYMENT.md` and `ANDROID.md` implement. Every requirement here carries an ID (`FR-*`, `NFR-*`, `BR-*`) that the other documents reference.

No application code is to be written until this document set is reviewed and signed off.

---

## 2. Source-of-truth status

| Input | Status | Impact |
|---|---|---|
| KasihKirim pitch deck | ✅ **Received and incorporated** (rev. 1.1) | Business model, commission, unit economics, launch corridor, categories, brand and the core Kirim interaction model are now authoritative. See §2.1 for what changed. |
| `CLAUDE.md` | ❌ **Still not present** in the workspace | Engineering conventions, repo layout rules and any pre-existing technical decisions remain unknown. Conventions in this document set are *proposed*, not inherited. If `CLAUDE.md` exists, it must be reconciled before code begins. |

### 2.1 What the deck changed

Most of the reconciliation was the anticipated data-and-copy exercise. **One change was structural** and is called out first.

| # | Finding in deck | Previous assumption | Severity |
|---|---|---|---|
| **1** | **Kirim is primarily a *procurement errand*, not a parcel shipment.** The deck's Step 1/4 screen asks *"Apa yang awak nak?"* — "What do you want?" — with a free-text item description, a category, an estimated weight, and a **budget cap (Had Bajet)** capped at RM 250. Copy reads *"Transfer tak akan beri lebih dari jumlah ini. Kalau harga pasar lebih tinggi, kita akan hubungi awak."* The carrier **buys the goods and brings them back**. | Kirim was modelled purely as "move my existing parcel from A to B" | **Structural.** Requires a new Kirim type, budget-cap enforcement, actual-cost reconciliation, receipt capture and refund-of-unspent-balance in the ledger. Addressed in §7.3a and `ARCHITECTURE.md` §7.3a. |
| 2 | Platform commission is **25 %** of order value; average order **RM 50**; revenue per order **RM 12.50** | 15 % delivery + 8 % goods | Data — `commission_rules` |
| 3 | Launch corridor is **Beluran ↔ Kota Kinabalu** (~250 km via Telupid) | KK↔Kudat / Keningau / Ranau | Data — route graph seed. Note the corridor is *long-haul*, which strengthens the return-leg thesis. |
| 4 | Categories are **Sayur, Buah, Hasil laut, Kraf, Lain-lain** | Generic taxonomy | Data — `categories` seed |
| 5 | Escrow releases **when the recipient confirms receipt** (*"dilepaskan apabila penerima mengesahkan barang sampai"*) | Time-window settlement | Rule — recipient confirmation is now the primary trigger, with the timer as fallback (BR-907 revised) |
| 6 | **Badges (Lencana)** are a visible profile feature — "Kirim Pertama" plus locked tiers | Not in scope | New — FR-319 |
| 7 | **Delivery vouchers run for the full first 12 months**, funded by the launch raise | Promotions were Phase 2 | Promoted to Phase 1 — FR-189 |
| 8 | Users belong to **multiple communities** ("2 Komuniti" on the profile) | Single home community | Schema — `community_members` join table |
| 9 | **Live animals** (`Ayam Hidup`) are an illustrated, first-class cargo class | Listed as an edge case | Confirmed handling flag |
| 10 | Brand system is defined: deep forest green / golden yellow / orange on cream, Bahasa Malaysia first, warm community tone | Unknown | Design tokens — §16 |

**Still assumed** (deck is silent): delivery pricing coefficients, agent programme economics, payout cycle, COD float limits, settlement window length, cancellation policy, liability cap. These remain in §14 and remain configuration rather than structure.

---

## 3. Problem statement

The deck states it plainly: **the kampung market already exists — it just lives in a WhatsApp status.**

- **The market is ephemeral.** Seafood and farm produce are sold daily as one photo, one price, one status. *"Bila status hilang, pasaran pun hilang, dan tiada rekod tinggal untuk sesiapa."* When the status expires, the market and the record expire with it.
- **There is no fixed place to sell or to buy.** Sellers hunt buyers one by one, group by group. Town buyers have nowhere they know to go. Income is therefore unpredictable — *pendapatan tidak stabil*.
- **Trust has no infrastructure.** WhatsApp and Facebook Marketplace have become the shop: scattered listings, unverifiable sellers, and **no transaction record when something goes wrong**.
- **Commercial couriers stop at the town.** Coverage ends at district capitals. Beluran to Kota Kinabalu is ~250 km via Telupid — far outside any economical last-mile courier service.
- **Addresses do not exist in machine-readable form.** Rural delivery is navigated by landmark and phone call, not street and postcode.
- **Yet the vehicles are already moving.** *"Setiap perjalanan ke pekan memang sudah berlaku."* Every journey to town is already happening. Pickups, 4WDs, vans and boats run town↔kampung daily, and the return leg is almost always empty.

KasihKirim formalises the existing informal *budaya kirim* — the culture of asking someone already travelling to bring something back — into a verified, recorded, escrow-backed peer-to-peer network. The empty space in a journey becomes trusted delivery capacity; the same route carries kampung produce to town.

---

## 4. Product concept

### 4.1 The three Kirim types

The deck's Kirim wizard is a *request for goods*, not a shipping label. This distinction drives the whole money model, so it is fixed here as a first-class type discriminator (`kirim_requests.kirim_type`).

| Type | Malay | What the requester says | Who buys the goods | Money shape |
|---|---|---|---|---|
| **`BELI`** *(procurement — the deck's primary flow)* | Kirim Beli | *"Udang galah saiz sederhana, 2 kg, hidup kalau ada. Had bajet RM 50."* | **The carrier buys it** en route and brings it back | Escrow = **goods budget cap + delivery fee**. Actual cost reconciled against the cap; unspent balance refunded. |
| **`HANTAR`** *(parcel)* | Kirim Hantar | *"Take this box from my house to my sister in KK."* | Nobody — goods already exist | Escrow = delivery fee only |
| **`PASARAN`** *(marketplace order)* | Kirim Pasaran | Generated by a marketplace checkout | The seller already owns it | Escrow = goods price + delivery fee |

`BELI` is the flow the deck illustrates and the one that captures the existing *budaya kirim* behaviour. `HANTAR` and `PASARAN` are the natural extensions that use the same carrier network and the same board.

### 4.2 The four surfaces

1. **Kirim** — the request. Four-step wizard: what you want → where → when → budget & confirm.
2. **Papan Kirim** *(the shared request board)* — *"Papan permintaan bersama. Penduduk kampung pos apa yang diperlukan; pembawa yang sudah menuju pekan ambil trip itu."* Residents post what they need; carriers already heading to town pick it up. The board also runs in reverse, showing announced trips to requesters.
3. **Kirim Balik / Muatan Balik** *(the return load)* — the carrier's inbound leg carries kampung produce to town. The deck names this as the **second revenue line**, deliberately excluded from the headline unit economics.
4. **Marketplace** — gives village produce the *fixed place to sell* that the WhatsApp-status economy lacks, and generates demand density on the same corridors.

Underneath all four sits the **community agent** layer, so that people without smartphones, banks or coverage still participate through a trusted village hub.

### 4.3 The trust mechanism

Three things convert an informal favour into a recorded transaction, and all three come straight from the deck:

- **Pembawa komuniti disahkan** — verified community carriers, not anonymous couriers.
- **Escrow secara lalai** — payment held by default, *"hanya dilepaskan apabila penerima mengesahkan barang sampai"*, released only on recipient confirmation.
- **A permanent record** — the thing a disappearing WhatsApp status can never provide.

### 4.1 Glossary

| Term | Meaning in this system |
|---|---|
| **Kirim** | A delivery request. The demand unit. |
| **Papan Kirim** | The public matching board (trips ↔ kirim requests). |
| **Kirim Balik** | A carrier's announced trip with declared spare capacity, typically a return leg. The supply unit. |
| **Carrier** | A verified individual moving cargo on a trip. Not an employee. |
| **Agent** | A verified community hub operator (often a kedai runcit owner) acting as drop point, cash point and onboarding assistant. |
| **Community** | A kampung / pekan / locality with a hub, used as an addressing anchor where street addresses fail. |
| **Node** | A point on the curated route graph (town, junction, jetty, kampung hub). |
| **Corridor** | An ordered sequence of nodes describing a trip's path. |
| **Leg** | One handover half of a delivery: `pickup` or `dropoff`. |
| **POD** | Proof of delivery. |
| **Sen** | 1/100 MYR. All money is stored as integer sen. |

---

## 5. Scope

### 5.1 In scope

- Android mobile application (Expo / React Native / TypeScript / Expo Router).
- Next.js admin console.
- Supabase backend (Postgres, Auth, Storage, Realtime, Edge Functions).

### 5.2 Explicitly out of scope

| Out of scope | Note |
|---|---|
| **iOS application** | Not to be built. No iOS targets in EAS config, no iOS-only dependencies, no `ios/` directory. Any dependency that is iOS-only is a rejected dependency. |
| Customer-facing web app | Admin console only. A minimal public web surface is required for legal reasons only (§13: account deletion URL, seller info disclosure). |
| Wear OS / Android TV / Automotive | No. |
| In-house payment processing | Licensed gateway only. See §13 compliance flags. |
| Warehousing / platform-owned fleet | The network is the fleet. |
| Cross-border (Sarawak, Labuan, Brunei, Kalimantan) | Post-MVP. Schema is state-aware so it does not block later. |

---

## 6. Users and personas

### P1 — Customer (rural recipient)
Aisyah, 34, Kampung Tinangol, Kudat district. Redmi A-series, 3 GB RAM, 32 GB storage with 4 GB free. Prepaid data, 3G at home, 4G when she goes to town. Orders for her household and for neighbours. Pays cash on delivery. Reads Bahasa Malaysia; treats English UI as a wall.

**Needs:** know a parcel is actually coming; a delivery address that works without a street name; pay on receipt; a person she can call.

### P2 — Customer (town buyer)
Jason, 28, Kota Kinabalu. Mid-range phone, stable 4G. Buys rural produce and handicraft. Pays by e-wallet or FPX. Wants a normal e-commerce experience.

### P3 — Seller (rural micro-producer)
Mdm Lidia, 47, Tambunan. Sells packaged food and handicraft. Phone camera is her only product-photography tool. Has a bank account at BSN. Not registered with SSM at onboarding; may register later.

**Needs:** list in under 5 minutes; know what she will be paid and when; not lose stock to unpaid orders.

### P4 — Carrier (opportunistic)
Rahman, 39, drives a Hilux Keningau↔KK twice a week for his own business. Return leg empty. Wants to cover fuel, not to become a courier company.

**Needs:** announce his trip in under 60 seconds; see what cargo fits *without detouring*; know his earnings before accepting; get paid reliably.

### P5 — Carrier (semi-professional)
Operates a van or small lorry, runs a fixed schedule, treats KasihKirim as a primary income line. Higher capacity, higher COD float, handles multi-stop.

### P6 — Community agent
Kedai runcit owner in a kampung. Acts as drop point, collects and remits COD cash, helps neighbours who have no smartphone place and receive orders. Earns per-parcel and per-onboarding commission.

**This persona is load-bearing.** It is the mechanism by which people outside the smartphone/banking/coverage envelope are still served, and the mechanism by which cash physically re-enters the system.

### P7 — Admin (ops / finance / support / compliance)
Desktop, office connectivity. Separate console. Segregated duties — see `SECURITY.md`.

---

## 7. Functional requirements

Priority: **M** = MVP, **1** = Phase 1, **2** = Phase 2.

### 7.1 Identity and account

| ID | Requirement | Pri |
|---|---|---|
| FR-100 | Register with Malaysian mobile number (`+60`) as sole identifier. No email required. | M |
| FR-101 | Verify by SMS OTP (6 digits, 5 min TTL, max 5 attempts, resend backoff 30/60/120 s). | M |
| FR-102 | WhatsApp OTP as an alternative channel where SMS delivery fails or is uneconomic. | 1 |
| FR-103 | Profile: display name, full legal name, avatar, preferred language, home community. | M |
| FR-104 | A single account may hold multiple roles simultaneously (customer + carrier + seller). Role switching must not require logout. | M |
| FR-105 | Session persists indefinitely unless revoked; refresh token rotation with reuse detection. Users must not be forced to re-OTP on normal use. | M |
| FR-106 | In-app account deletion request, with a public web equivalent (Play policy). Financial records are pseudonymised, not destroyed — see BR-902. | M |
| FR-107 | Change phone number, re-verifying both old and new numbers. | 1 |
| FR-108 | Block/report another user. | 1 |

### 7.2 Addresses (rural addressing)

| ID | Requirement | Pri |
|---|---|---|
| FR-120 | An address is `community` + `landmark_note` + optional coordinates + recipient name/phone. Street/postcode are **optional**, never required. | M |
| FR-121 | Capture GPS at address-creation time when the user is physically there ("Set from where I am now"), with accuracy recorded. | M |
| FR-122 | Attach a photo of the destination (house, gate, junction) to an address. This is the primary navigation aid. | M |
| FR-123 | Every address resolves to a nearest `route_node` for matching; resolution is server-side. | M |
| FR-124 | Addresses may designate an agent hub as the delivery point instead of a physical house. | M |
| FR-125 | Multiple saved addresses with one default. | M |
| FR-126 | Voice note attached to an address for directions (low-literacy support). | 2 |

### 7.3 Kirim (delivery request)

| ID | Requirement | Pri |
|---|---|---|
| FR-140 | Create a Kirim in a **4-step wizard** matching the deck: (1) what you want — item description, category, estimated weight, budget cap; (2) where — pickup/destination; (3) when — day and coarse window; (4) review and confirm. | M |
| FR-140a | Kirim type is `BELI`, `HANTAR` or `PASARAN` (§4.1) and determines which wizard fields apply. | M |
| FR-140b | Category selector: **Sayur, Buah, Hasil laut, Kraf, Lain-lain**. | M |
| FR-140c | Weight is an *estimate* entered with a ± stepper defaulting to 1.0 kg — not a precise measurement. Pricing must tolerate estimate error (BR-914). | M |
| FR-141 | Handling flags: fragile, perishable/cold, liquid, oversized, livestock, documents-only. Flags gate which vehicles may match. | M |
| FR-142 | Server returns a binding **quote** (fee breakdown + expiry). The client never computes price. | M |
| FR-143 | Choose visibility: post to Papan Kirim (open) or direct-offer to a specific carrier/trip. | M |
| FR-144 | Pickup and delivery time windows, expressed as day + coarse window (morning/afternoon/evening), not exact times. | M |
| FR-145 | Cancel before pickup, subject to the cancellation policy (BR-905). | M |
| FR-146 | A Kirim that receives no match before its expiry auto-expires and notifies the requester. | M |
| FR-147 | Re-post an expired or carrier-cancelled Kirim in one tap, preserving details. | M |
| FR-148 | Multi-parcel Kirim (several items, one journey). | 2 |
| FR-149 | Apply a delivery voucher at Kirim creation; discount is computed and applied server-side. | M |

### 7.3a Kirim Beli — procurement with a budget cap

The deck's primary flow. The carrier spends the requester's money on their behalf, which makes this the highest-trust and highest-risk interaction in the product.

| ID | Requirement | Pri |
|---|---|---|
| FR-150 | Requester sets a **budget cap** (`Had Bajet`) for goods, separate from the delivery fee. Platform maximum **RM 250** per Kirim. | M |
| FR-151 | The cap is a **hard ceiling**. The carrier can never be reimbursed above it without an explicit, recorded requester approval. | M |
| FR-152 | If market price exceeds the cap, the carrier raises a **price variance request** with the actual price and a photo. The requester approves an increase, accepts a reduced quantity, or cancels. Deck copy: *"Kalau harga pasar lebih tinggi, kita akan hubungi awak."* | M |
| FR-153 | Variance requests must work when the requester is offline: they queue, notify by push then SMS, and expire to a safe default (cancel, no purchase) after a timeout. | M |
| FR-154 | Carrier records **actual goods cost** and uploads a **receipt or price photo** at purchase. | M |
| FR-155 | Unspent budget (`cap − actual_cost`) is **automatically refunded** to the requester at settlement. It is never retained by the carrier or the platform. | M |
| FR-156 | Item quality/substitution: carrier may propose a substitute with a photo; requester accepts or declines before purchase. | 1 |
| FR-157 | Goods that could not be found at all → `PROCUREMENT_FAILED`; full goods refund, delivery fee handled per policy. | M |
| FR-158 | Carrier out-of-pocket exposure is capped by the same float mechanism as COD (BR-908) — a carrier cannot hold more advanced-purchase exposure than their tier permits. | M |
| FR-159 | Requester sees a clear three-part breakdown before paying: **goods budget + delivery fee + platform commission**, with a plain statement that unspent budget is returned. | M |

### 7.4 Papan Kirim (the board)

| ID | Requirement | Pri |
|---|---|---|
| FR-160 | Carrier view: open Kirim requests ranked by fit against the carrier's declared trips. | M |
| FR-161 | Customer view: announced trips passing their corridor, with capacity and departure. | M |
| FR-162 | Filters: corridor, date, weight, handling class, COD accepted, price. | M |
| FR-163 | Ranking is **server-computed** (`match_score`) and returned pre-ranked. The client does not re-sort by score. | M |
| FR-164 | Board is paginated by keyset cursor, page size ≤ 20, and is cacheable offline (read-only) for the last-synced page. | M |
| FR-165 | Offers: carrier offers on a Kirim, or customer requests a slot on a trip. Either side may accept. | M |
| FR-166 | Offers expire (default 2 h) and auto-release any held capacity. | M |
| FR-167 | Counter-offer on price, within a server-enforced band around the quote (BR-906). | 1 |

### 7.5 Marketplace

| ID | Requirement | Pri |
|---|---|---|
| FR-180 | Browse and search products by category, community, seller, price. | M |
| FR-181 | Product detail with images, weight/dimensions, handling class, seller rating, **delivery quote to my address computed before add-to-cart**. | M |
| FR-182 | Cart is **server-held**. Prices, stock and delivery are re-validated at checkout. | M |
| FR-183 | Multi-seller cart splits into one order per seller under a single order group and single payment. | M |
| FR-184 | Checkout: address, delivery option, payment method, quote confirmation. | M |
| FR-185 | Stock is reserved at checkout with TTL, released on payment failure or expiry. | M |
| FR-186 | Order history, order detail, reorder. | M |
| FR-187 | Product Q&A / seller enquiry via chat. | 1 |
| FR-188 | Community-level campaigns and seller promotions. | 2 |
| FR-189 | **Delivery vouchers** — the deck commits to a voucher programme running the full first 12 months, funded from the launch raise. Requires: voucher definitions, issuance rules, per-user redemption limits, expiry, budget ceiling with automatic cut-off, and redemption reporting. Discounts are computed server-side and posted to `PROMO_EXPENSE` in the ledger so campaign burn is measurable against the raise. | **M** |

### 7.6 Payment

| ID | Requirement | Pri |
|---|---|---|
| FR-200 | Methods: FPX, DuitNow QR, e-wallet (TNG / GrabPay / Boost / ShopeePay), card, **Cash on Delivery**. | M |
| FR-201 | COD availability is server-decided per delivery: carrier float headroom, customer COD standing, order value ceiling, corridor policy. | M |
| FR-202 | Prepaid funds are held in escrow until delivery completion + settlement window. | M |
| FR-203 | Payment status is driven solely by verified gateway webhooks. Client-reported success is a hint, never a state change. | M |
| FR-204 | Webhook processing is idempotent and replay-safe. | M |
| FR-205 | Refunds: full, partial, to original method or to wallet credit. Admin-initiated or dispute-resolved. | M |
| FR-206 | Every payment, refund, commission and payout produces balanced double-entry ledger records. | M |
| FR-207 | Customer sees a plain-language fee breakdown before paying — no hidden charges. | M |

### 7.7 Delivery execution, QR and OTP

| ID | Requirement | Pri |
|---|---|---|
| FR-220 | All delivery state transitions are executed server-side. The client submits *events*, never states. | M |
| FR-221 | **Pickup handover** requires proof: QR scan (preferred) or 6-digit OTP (fallback) or agent confirmation. | M |
| FR-222 | **Delivery handover** requires proof: QR scan, or recipient OTP, or agent confirmation, or photo POD + geotag (weakest, auto-flags for review). | M |
| FR-223 | Handover proof must be capturable **fully offline** and sync later without loss or duplication. | M |
| FR-224 | QR tokens are cryptographically signed, single-use, and verifiable server-side after an offline scan. | M |
| FR-225 | OTP codes are stored hashed, rate-limited, attempt-capped, and rotatable on request. | M |
| FR-226 | Customer sees live-ish delivery status; precise carrier location is shared only while `IN_TRANSIT` and only to the counterparties of that delivery. | M |
| FR-227 | Failed delivery paths: recipient absent, refused, wrong location, unreachable — each with a defined next action (retry, hub, return). | M |
| FR-228 | Photo POD is compressed on-device to ≤ 200 KB before queueing. | M |

### 7.8 Carrier and Kirim Balik

| ID | Requirement | Pri |
|---|---|---|
| FR-240 | Carrier verification: identity (MyKad), selfie liveness check, driving licence, vehicle registration, vehicle photos. | M |
| FR-241 | Register one or more vehicles: type (motorcycle / car / pickup / 4WD / van / lorry / **boat**), plate, capacity (weight, volume, parcel count), handling capabilities. | M |
| FR-242 | Announce a trip: origin node → via nodes → destination node, departure window, and spare capacity **per dimension** (kg, volume, parcels). | M |
| FR-243 | One-tap "announce the return leg" that mirrors a completed trip. This is the Kirim Balik primitive. | M |
| FR-244 | Save and reuse recurring trips (e.g. every Tue/Fri KK↔Keningau). | 1 |
| FR-245 | System proposes matching cargo for the announced trip, ranked, with **earnings shown before acceptance**. | M |
| FR-246 | Accepting cargo **atomically** reserves capacity. Overbooking must be structurally impossible (BR-903). | M |
| FR-247 | Trip manifest: ordered stops, each with parcel, contact, address photo, handover method, COD amount. | M |
| FR-248 | Manifest is fully available offline once the trip starts. | M |
| FR-249 | Earnings dashboard: per delivery, per trip, per period, with pending vs available split. | M |
| FR-250 | Payout request to a verified bank account; server-controlled state machine. | M |
| FR-251 | COD reconciliation: cash collected, cash owed, remittance history, float headroom remaining. | M |
| FR-252 | Carrier may not accept COD cargo beyond their float limit. Enforced server-side. | M |

### 7.9 Seller

| ID | Requirement | Pri |
|---|---|---|
| FR-270 | Seller application: business name, category, community, contact, bank account, optional SSM/ROB number. | M |
| FR-271 | Admin verification with tiers; unverified sellers cannot publish. | M |
| FR-272 | Create/edit product: title, description, category, price, weight, dimensions, handling class, images (max 6). | M |
| FR-273 | Images compressed on-device (long edge ≤ 1280 px, ≤ 200 KB) before upload; resumable upload. | M |
| FR-274 | Inventory per variant with reserved/available split and an append-only movement log. | M |
| FR-275 | Order queue: accept / reject / mark ready for pickup, with an acceptance SLA. | M |
| FR-276 | Sales dashboard and settlement statement. | M |
| FR-277 | Payout request; same state machine as carrier payouts. | M |
| FR-278 | Product status: draft / pending review / active / paused / rejected / delisted. | M |

### 7.10 Community agent

| ID | Requirement | Pri |
|---|---|---|
| FR-290 | Agent application and verification, bound to exactly one community. | 1 |
| FR-291 | Hub intake: accept a parcel into the hub, generating a hub custody event. | 1 |
| FR-292 | Hub release: hand a parcel to recipient or onward carrier with proof. | 1 |
| FR-293 | Assisted ordering: place an order on behalf of a walk-in resident who has no smartphone. | 1 |
| FR-294 | COD cash collection point and remittance workflow. | 1 |
| FR-295 | Agent commission accrual and payout. | 1 |

### 7.11 Trust and safety

| ID | Requirement | Pri |
|---|---|---|
| FR-310 | Rate and review counterparties after completion. Ratings are double-blind until both submit or 7 days elapse. | M |
| FR-311 | One review per party per transaction; edit window 24 h; no deletion after publication. | M |
| FR-312 | Aggregate ratings maintained incrementally, never computed by full scan. | M |
| FR-313 | Raise a dispute: non-delivery, damage, wrong item, not as described, payment issue, conduct. | M |
| FR-314 | Disputes hold escrow release until resolved. | M |
| FR-315 | Evidence upload (photos, chat excerpts) to a private bucket with signed, expiring access. | M |
| FR-316 | Report content or a user; admin moderation queue. | M |
| FR-317 | Chat between counterparties, scoped to a transaction, closed N days after completion. | M |
| FR-318 | Chat is monitored for off-platform payment solicitation and contact-detail leakage patterns; flagged for review. | 1 |
| FR-319 | **Badges (Lencana)** on the profile, earned and locked tiers, starting with "Kirim Pertama". Badge rules are data-driven (`badge_definitions`) and awarded server-side only. | M |
| FR-320 | Profile displays: rating, Kirim completed, Kirim received, **communities joined**, badges, and unreleased earnings. | M |
| FR-321 | A user may belong to **multiple communities**; community membership drives board relevance and locality bonuses in matching. | M |

### 7.12 Notifications

| ID | Requirement | Pri |
|---|---|---|
| FR-330 | Push notifications for: new match, offer received/accepted, pickup due, out for delivery, delivered, payment result, payout result, dispute update, chat message. | M |
| FR-331 | Android notification channels per category, so users can mute promos without muting delivery events. | M |
| FR-332 | **In-app notification inbox is the source of truth.** Push is best-effort. | M |
| FR-333 | Critical events (new match, handover OTP, COD amount) fall back to SMS if push is unacknowledged within a threshold. | M |
| FR-334 | Per-category notification preferences. | 1 |
| FR-335 | All notification copy is localised (ms-MY primary). | M |

### 7.13 Admin console

| ID | Requirement | Pri |
|---|---|---|
| FR-350 | User management: search, view, suspend, restore, role grant/revoke. | M |
| FR-351 | Verification queues (seller, carrier, agent) with document viewer, approve/reject + reason, tiering. | M |
| FR-352 | Product moderation queue. | M |
| FR-353 | Order and delivery inspection with full event timeline. | M |
| FR-354 | Manual delivery state override — permitted, but always as a recorded admin event with mandatory reason. | M |
| FR-355 | Payment inspection, webhook replay, reconciliation view. | M |
| FR-356 | Payout approval workflow with maker/checker separation above a threshold. | M |
| FR-357 | Dispute workspace with SLA timers and resolution actions. | M |
| FR-358 | Community and route-graph management: nodes, edges, zones, agents. | M |
| FR-359 | Analytics: GMV, delivery volume, fill rate, match rate, on-time rate, COD exposure, cancellation reasons, corridor heat. | 1 |
| FR-360 | Immutable audit log of every admin action, searchable. | M |
| FR-361 | Fraud queue driven by risk signals; block/allow/escalate. | 1 |
| FR-362 | Pricing rule and commission rule management with effective dating and preview. | 1 |

---

## 8. Business rules

These are invariants. They are enforced in the database and/or Edge Functions, never only in the client.

| ID | Rule |
|---|---|
| BR-900 | **All money is computed server-side.** The client displays server-issued amounts. Any client-supplied amount in a request is ignored, and its presence is logged as a risk signal. |
| BR-901 | **Money is integer `sen`.** No floating point anywhere in the money path — not in Postgres, not in TypeScript, not in JSON. |
| BR-902 | **Financial records are never deleted.** Account deletion pseudonymises the actor; ledger, payment, payout and tax records are retained for the statutory period (§13). |
| BR-903 | **Overbooking is structurally impossible.** Trip capacity is protected by a row lock during reservation *and* a database CHECK constraint on reserved ≤ capacity. Application logic is the third line of defence, not the first. |
| BR-904 | **Delivery state changes only via the server transition function**, validated against a transition rule table. Direct UPDATE on state columns is revoked for all non-service roles. |
| BR-905 | Cancellation windows and fees are policy-table driven, evaluated server-side against the current state and elapsed time. |
| BR-906 | Negotiated prices must remain inside a server-enforced band around the system quote (default ±20 %, configurable). Outside the band, the offer is rejected. |
| BR-907 | **Escrow releases on recipient confirmation.** Per the deck — *"dilepaskan apabila penerima mengesahkan barang sampai"* — the primary trigger is the recipient confirming receipt. A time-based auto-release after the settlement window is the *fallback only*, so that an unresponsive or offline recipient cannot strand a carrier's earnings indefinitely. Either path additionally requires: state is `DELIVERED`, and no dispute is open. |
| BR-908 | A carrier's outstanding COD held may never exceed their float limit. Enforced at the point of accepting cargo. |
| BR-909 | Payout requests require an available (not pending) balance and a verified bank account, and are approved through the payout state machine. |
| BR-910 | A user may not review, rate, dispute against, or transact with themselves. Enforced by constraint and by risk rules on shared device/bank/phone. |
| BR-911 | Every mutating API call carries an idempotency key. Replays return the original result, never a second effect. |
| BR-912 | Commission and platform fee records are written only by the settlement engine and are read-only to every non-service role. |
| BR-913 | **A carrier can never be reimbursed above the budget cap** without a recorded requester approval carrying an actor, timestamp and the quoted actual price. Enforced by constraint: `reimbursed_sen <= budget_cap_sen` unless a linked approved `price_variance` exists. |
| BR-914 | Weight is a **user estimate**. The quote is binding at the estimate; if actual weight exceeds it beyond a tolerance band, the difference is handled by a recorded variance, never by silently charging more. |
| BR-915 | **Unspent procurement budget always returns to the requester.** It may not be retained as revenue, converted to credit without consent, or absorbed by the carrier. Enforced by a settlement invariant: `goods_escrow = actual_cost + refund`. |
| BR-916 | Voucher discounts are computed server-side, are single-use per issuance, respect a per-campaign budget ceiling, and post to `PROMO_EXPENSE`. A voucher can never produce a negative payable to a carrier or seller — the platform absorbs the discount, not the counterparty. |
| BR-917 | Badges are awarded only by server-side rule evaluation. They are cosmetic and must never influence pricing, payout or dispute outcomes. |

---

## 9. Non-functional requirements

### 9.1 Device envelope

| ID | Requirement |
|---|---|
| NFR-100 | Target device floor: 2 GB RAM, Android 7.0 (API 24), quad-core ARMv8, 720×1280, ~1 GB free storage. |
| NFR-101 | Download size (AAB delivered, per-ABI) ≤ 25 MB. Installed size ≤ 90 MB. Hard CI gate. |
| NFR-102 | Cold start to interactive ≤ 3.5 s on the floor device. |
| NFR-103 | Steady-state JS heap ≤ 180 MB on the floor device; no OOM in a 30-minute soak. |
| NFR-104 | App-managed cache is bounded at 150 MB with LRU eviction and a user-visible "clear cache" control. |
| NFR-105 | List scrolling maintains ≥ 50 fps on the floor device with virtualised lists. |

### 9.2 Network envelope

| ID | Requirement |
|---|---|
| NFR-120 | Usable on 3G at ~400 kbps with 400 ms RTT and 3 % packet loss. |
| NFR-121 | Any single screen's initial payload ≤ 50 KB compressed. |
| NFR-122 | All list endpoints are keyset-paginated, page size ≤ 20, with explicit field selection. |
| NFR-123 | Every network call has a timeout, bounded retries with exponential backoff + jitter, and a circuit breaker. |
| NFR-124 | Images are served pre-resized via Storage transforms; the app never downloads a full-resolution original for display. |
| NFR-125 | Monthly data budget for a typical customer ≤ 40 MB; "Jimat Data" (data saver) mode reduces this to ≤ 15 MB by suppressing non-essential imagery. |

### 9.3 Offline envelope

| ID | Requirement |
|---|---|
| NFR-140 | These work with **zero connectivity**: view active deliveries and manifest, scan QR handover, enter OTP handover, capture POD photo, draft a Kirim, read cached board/orders. |
| NFR-141 | Queued mutations survive app kill and device reboot. |
| NFR-142 | Reconnection produces no duplicate financial or state effects, guaranteed by idempotency keys. |
| NFR-143 | Queue depth and sync state are always visible to the user in plain language ("3 perkara menunggu talian"). |
| NFR-144 | Offline-captured proofs record both device time and server receipt time; implausible clock skew is flagged, not silently trusted. |

### 9.4 Availability, performance, scale

| ID | Requirement |
|---|---|
| NFR-160 | Availability target 99.5 % monthly for core transactional paths. |
| NFR-161 | API p95 ≤ 400 ms server-side (excluding client network) for reads; ≤ 800 ms for transactional writes. |
| NFR-162 | Match computation for a trip p95 ≤ 1.5 s at 10 000 open Kirim requests. |
| NFR-163 | Year-1 planning envelope: 50 000 users, 3 000 MAU carriers, 20 000 deliveries/month, 200 000 board impressions/day. |
| NFR-164 | RPO ≤ 5 min (PITR), RTO ≤ 4 h. |
| NFR-165 | Daily automated ledger reconciliation; any imbalance pages on-call immediately. |

### 9.5 Security, privacy, accessibility

| ID | Requirement |
|---|---|
| NFR-180 | Every table carries RLS with default-deny. See `SECURITY.md`. |
| NFR-181 | KYC documents live in private buckets, accessed only by short-lived signed URLs, never public. |
| NFR-182 | PII is minimised in logs; phone numbers and NRIC are masked in all non-privileged surfaces. |
| NFR-183 | Compliant with Malaysia's PDPA 2010 principles: notice, consent, purpose limitation, retention, access, security. |
| NFR-184 | Touch targets ≥ 48 dp; contrast ≥ 4.5:1; full TalkBack labelling; UI survives 200 % system font scale without truncation. |
| NFR-185 | Primary language Bahasa Malaysia. No English-only screen may exist in a critical flow. |
| NFR-186 | Critical numeric information (COD amount, OTP, weight) is rendered in a large, high-contrast, unambiguous style. |

---

## 10. Release phasing

| Phase | Contents | Exit criteria |
|---|---|---|
| **P0 — Foundations** | Schema, RLS, auth, CI/CD, admin shell, **Beluran ↔ Kota Kinabalu corridor seeded** (via Telupid), Kg Kepayan Baru / Sepanggar and Beluran communities | RLS test matrix green; migrations reproducible from zero |
| **P1 — Closed pilot** | Kirim `BELI` + `HANTAR`, Papan Kirim, Kirim Balik, matching, QR/OTP handover, budget-cap procurement with variance flow, COD only, no marketplace | 50 real deliveries on the Beluran corridor, zero money discrepancies, zero overbooking incidents, zero budget-cap breaches |
| **P2 — Payments** | Prepaid methods, escrow, settlement, payouts, disputes | 30 days of clean daily reconciliation |
| **P3 — Marketplace** | Sellers, products, inventory, cart, checkout | 20 active sellers, seller payout cycle completed twice |
| **P4 — Agents & scale** | Agent hubs, assisted ordering, cash remittance, analytics, fraud rules | Agent network live in 5 communities |

Public Play launch is gated on P2 completion; P1 runs via Play **closed testing**.

---

## 11. Success metrics

| Metric | Definition | Target (12 mo) |
|---|---|---|
| Match rate | Kirim requests matched within 24 h | ≥ 70 % |
| Fill rate | Declared trip capacity actually consumed | ≥ 45 % |
| On-time rate | Delivered within the promised window | ≥ 85 % |
| Handover integrity | Deliveries closed with QR or OTP proof (not photo-only) | ≥ 95 % |
| COD leakage | Cash collected but unremitted past SLA | ≤ 0.5 % of COD value |
| Dispute rate | Disputes per 100 completed deliveries | ≤ 2 |
| Ledger integrity | Days with a non-zero reconciliation variance | **0** |
| Crash-free sessions | Play Vitals | ≥ 99.3 % |
| ANR rate | Play Vitals | ≤ 0.35 % |
| P50 data per session | Measured client-side | ≤ 600 KB |

### 11.1 Commercial metrics (from the deck)

These are the business targets the product is accountable to. The platform must **instrument them directly** — each maps to a query over the ledger and order tables, not to a spreadsheet.

| Metric | Deck value | Where it is measured |
|---|---|---|
| Average order value | **RM 50** | `orders.total_sen` / `kirim_requests` mean |
| Platform commission | **25 %** | `commission_rules` → `PLATFORM_COMMISSION` ledger account |
| Revenue per order | **RM 12.50** | `PLATFORM_COMMISSION` credits ÷ completed orders |
| Gross margin | **78 %** | Revenue − (gateway fees + SMS + variable infra) |
| CAC | **RM 25** | `PROMO_EXPENSE` + ad spend ÷ new activated users |
| LTV | **RM 120** | Cumulative commission per user cohort |
| LTV : CAC | **4.8×** | Derived |
| **Break-even** | **513 active customers** | Monthly active requesters with ≥1 completed Kirim |
| Voucher burn | Within the RM 500k raise | `PROMO_EXPENSE` against campaign ceiling — **hard cut-off when exhausted** |

The deck notes that the **second revenue line — Kirim Balik return load and kampung produce aggregation — is deliberately excluded** from these figures. It should be tracked separately from day one so its contribution is visible rather than blended.

---

## 12. Key product decisions and their rationale

| Decision | Rationale | Rejected alternative |
|---|---|---|
| Community + landmark addressing, coordinates optional | Rural Sabah has no reliable street addressing; forcing structured addresses produces garbage data | Mandatory postcode/street |
| Curated route-node graph instead of live routing APIs | Sparse rural road network, poor connectivity, and per-call cost make live routing both unnecessary and fragile; a curated graph also encodes local knowledge | Google Directions / OSRM polyline matching |
| Server-held cart and server-issued quotes | Removes an entire class of price-tampering attacks and keeps pricing changeable without a store release | Client-side cart and price calculation |
| Double-entry ledger from day one | Retrofitting correct accounting onto a live payouts system is close to impossible; commissions, COD and refunds make single-column balances unsafe | `users.balance` column |
| QR primary, OTP fallback, agent tertiary, photo last | Recipients may have no smartphone, no signal, or no literacy in the app's language; a single proof mechanism excludes real users | QR-only handover |
| Foreground-service tracking, no background location | Avoids Google Play's sensitive-permission review burden and is honest about battery use | `ACCESS_BACKGROUND_LOCATION` |
| In-app inbox as notification source of truth | Aggressive battery managers on budget Chinese OEM ROMs — very common in this market — silently kill push | Push-only notifications |
| Offline-verifiable signed QR tokens | Handover happens where there is no signal; verification must be deferrable without weakening it | Server round-trip at scan time |
| Android-only, no shared iOS abstraction cost | Explicit brief; avoids paying cross-platform tax for a platform that will not ship | Cross-platform parity |

---

## 13. Compliance and legal register

**Not legal advice.** These are flagged as items requiring qualified Malaysian legal review before public launch. Several are potentially blocking.

| ID | Area | Concern | Owner |
|---|---|---|---|
| LGL-01 | **Courier licensing** | Carriage of goods for reward in Malaysia is a licensed activity. Courier service licensing sits with MCMC under the Postal Services Act 2012; commercial goods-vehicle licensing in Sabah sits with the CVLB. A crowdsourced carrier network's status under both regimes must be determined before launch. | Legal |
| LGL-02 | **Holding customer funds** ⚠️ **Escalated** | The deck states this as a headline feature: *"Bayaran dipegang platform secara lalai"* — payment held by the platform by default. Holding customer money in escrow may constitute a regulated payment or e-money activity under Bank Negara Malaysia. **This is a potential launch blocker and needs an answer before the payment phase begins.** Preferred mitigation: the licensed gateway or a licensed partner holds the funds and KasihKirim only instructs the splits — which is exactly why the ledger is designed as a *record of claims* rather than a wallet the platform banks. The `BELI` flow compounds this: the platform would be holding money earmarked for a third-party purchase. | Legal / Finance |
| LGL-12 | **Carrier acting as purchasing agent** | In `BELI`, the carrier buys goods with the requester's money. This creates an agency relationship with its own consumer-protection and tax consequences (who is the seller of record? is the carrier making a taxable supply?). Also raises practical risk: purchasing prohibited or age-restricted goods on request. | Legal / Ops |
| LGL-03 | **PDPA 2010** | Notice and choice, disclosure, security, retention, data integrity, access principles. Requires a published privacy notice in Bahasa Malaysia and English, and a working data-access/deletion path. | Legal |
| LGL-04 | **Consumer Protection (Electronic Trade Transactions) Regulations 2012** | Online marketplaces must disclose seller identity, business registration, contact details, and maintain transaction records. Affects seller onboarding fields and product page UI. | Legal / Product |
| LGL-05 | **Google Play — financial features** | Declaration required. Physical goods and real-world services must **not** use Play Billing; external payment is correct and permitted here. Must be declared accurately. | Mobile lead |
| LGL-06 | **Google Play — account deletion** | In-app deletion plus a publicly reachable web URL. Retention exceptions must be disclosed. | Mobile lead |
| LGL-07 | **Google Play — Data Safety** | Full disclosure of collected data: phone, precise location, photos, financial info, device identifiers; purposes, sharing, encryption, deletion. | Mobile lead |
| LGL-08 | **Insurance / liability** | Who bears loss for damaged or lost cargo — carrier, platform, declared-value cap, or an insurance partner? Declared value is captured but the liability model is undecided. | Business |
| LGL-09 | **Carrier employment status** | Classification risk for gig carriers. | Legal |
| LGL-10 | **Tax** | SST applicability on service fees; e-invoicing (LHDN MyInvois) obligations for platform fees and seller settlements; 7-year record retention. | Finance |
| LGL-11 | **Prohibited goods** | Category blocklist and enforcement for items that may not be carried (controlled substances, weapons, live animals subject to permit, wildlife under Sabah Wildlife Conservation Enactment). | Ops / Legal |

---

## 14. Assumption register

### 14.1 Confirmed by the deck — implement as stated

| ID | Value | Absorbed by |
|---|---|---|
| C-01 | Platform commission **25 % of order total** (goods budget + delivery fee), paid to the platform | `commission_rules` (`party='platform'`, `basis='order_total'`, `rate_bps=2500`) |
| C-02 | Average order **RM 50**, revenue per order **RM 12.50** | Analytics baseline |
| C-03 | Budget cap maximum **RM 250** per Kirim | `app_config.max_budget_cap_sen` |
| C-04 | Launch corridor **Beluran ↔ Kota Kinabalu** | `route_nodes` / `route_edges` seed |
| C-05 | Categories: Sayur, Buah, Hasil laut, Kraf, Lain-lain | `categories` seed |
| C-06 | Escrow release on recipient confirmation | BR-907 |
| C-07 | Voucher programme for 12 months from launch | `voucher_campaigns` |
| C-08 | Multi-community membership | `community_members` |
| C-09 | Badges from first Kirim onward | `badge_definitions` |
| C-10 | Live animals as a cargo class | `handling_flags` |
| C-11 | Brand palette and BM-first tone | Design tokens — §16 |
| C-12 | Break-even 513 active customers; RM 500k raise | Analytics targets |

### 14.2 Still assumed — deck is silent, confirm with the founders

| ID | Assumption | Absorbed by |
|---|---|---|
| A-03 | Agent commission: **RM 1.00 per parcel handled + 2 % of COD remitted** | `agents.commission_rate_bps`, `commission_rules` |
| A-04 | **Delivery fee formula: `base + corridor_band + per_kg + handling`.** Distance is priced as a *band*, not per-km. Rationale: the carrier is already making the journey, so marginal cost of one more parcel is near zero. Per-km pricing produced RM 120 on the Beluran↔KK corridor against a deck order value of RM 50 — the model does not survive it. | `pricing_rules.params` |
| A-05 | Base **RM 5.00**; RM 1.50/kg above 1 kg included; corridor bands local RM 0 / district RM 3 / regional RM 5 / **long-haul RM 8**. Yields **RM 15.50** on Beluran→KK, giving an RM 50.50 order and RM 12.63 commission — within 1 % of the deck's RM 50 / RM 12.50. | `pricing_rules.params` |
| A-06 | Volumetric divisor **5000** (cm³ → kg) | `pricing_rules.params.volumetric_divisor` |
| A-07 | Settlement fallback window: **48 h** after `DELIVERED` if the recipient does not confirm | `app_config.settlement_window_hours` |
| A-08 | Payout cycle: weekly, minimum **RM 20** | `app_config.payout_*` |
| A-09 | Default COD / procurement-advance float limit: **RM 500**, tier-adjusted | `carriers.cod_float_limit_sen` |
| A-11 | Negotiation band ±20 % of quote | `app_config.offer_band_bps` |
| A-12 | Offer TTL 2 h; capacity hold 30 min; quote 15 min; price-variance response 2 h | `app_config.*_ttl_*` |
| A-13 | Cancellation free before `MATCHED`; fee after; **free before goods are purchased** for `BELI` | `cancellation_policies` |
| A-14 | Review visibility: double-blind, 7-day reveal | `app_config.review_reveal_days` |
| A-15 | Declared-value cap **RM 1 000** per parcel pending LGL-08 | `app_config.max_declared_value_sen` |
| A-16 | Gateway: Malaysian provider supporting FPX + DuitNow + e-wallets, behind an adapter | `payment_providers` |
| A-19 | **Who funds the carrier's purchase float** — carrier's own cash, platform advance, or agent hub. Affects LGL-02 and carrier onboarding. | Ledger design |

---

## 15. Open questions for the business

Answered by the deck: launch geography (Beluran ↔ KK), commission rate (25 %), brand system, escrow release trigger.

Still open, in priority order:

1. **Is the platform holding funds, or is the gateway?** Blocks LGL-02, and the deck markets platform-held escrow as a core feature. Highest priority.
2. **Who funds the carrier's purchase float in `BELI`?** If the carrier fronts the cash, carrier acquisition gets much harder; if the platform advances it, LGL-02 deepens.
4. Who bears cargo loss, and what is the liability cap? (blocks LGL-08 and the dispute matrix)
5. What is the COD / procurement remittance SLA, and the consequence of breach?
6. Is the agent programme salaried, commissioned, or franchise-like?
7. Who curates the route graph on the ground for the Beluran corridor?
8. What identity assurance is required for carriers — MyKad + selfie, or full eKYC via a licensed provider?
9. Are there partnership commitments (state agencies, cooperatives, telcos) that impose requirements?
10. Voucher economics: per-voucher value, monthly ceiling, and stop-loss rule?
11. Does `CLAUDE.md` contain repo conventions that contradict anything proposed here?

---

## 16. Business model and brand

### 16.1 Unit economics (deck, slide 07)

```
RM 50 average order  ──►  25% platform commission  ──►  RM 12.50 revenue per order

Gross margin      78%
CAC               RM 25
LTV               RM 120
LTV : CAC         4.8×
Break-even        513 active customers
Raise sought      RM 500,000  (app build, team, vouchers, ads, branding — 12 months)
```

Second revenue line, excluded from the above by design: **Kirim Balik return load** and **kampung produce aggregation**. Track it separately from day one so its contribution is visible rather than blended.

**Engineering consequence.** At RM 12.50 revenue per order, per-transaction cost is a real percentage of margin. Every SMS, gateway fee and Edge Function invocation matters. This is the direct justification for the architecture's cost choices: PostgREST over Edge Functions for reads, push before SMS, a curated distance matrix instead of a paid routing API, and aggressive payload minimisation.

### 16.2 Brand

| Token | Value | Use |
|---|---|---|
| `--kk-green-900` | Deep forest green | Primary surfaces, headers, primary buttons |
| `--kk-green-600` | Mid green | Secondary surfaces, success states |
| `--kk-yellow-500` | Golden yellow | Accents, badges, highlight chips |
| `--kk-orange-500` | Warm orange | Primary CTA ("Teruskan"), headline emphasis |
| `--kk-cream-50` | Cream / off-white | Page background |
| Display type | Heavy condensed uppercase | Headlines |
| Body type | Humanist sans | Body, forms |
| Script accent | Handwritten | Warmth only — never for information |

Tone: warm, communal, direct. **Bahasa Malaysia first** — the deck's UI is entirely in BM, including microcopy. English is a secondary locale, never the default.

- Positioning: *"Kirim dengan kasih, dari kampung ke bandar."*
- Trust: *"Budaya kirim, kini dipercayai."*
- Values surfaced in-product: **Selamat · Punctual · Bermakna · Membina ekonomi kampung.**

### 16.3 Company

| | |
|---|---|
| Founder & CEO | Saila Saidie |
| Co-founders | Demeero Saidi, Juli Apang |
| Base | Kampung Kepayan Baru, Sepanggar, Kota Kinabalu, Sabah |
| Web | www.kasihkirim.com · hello@kasihkirim.com |

---

## 17. Sign-off

| Role | Name | Decision | Date |
|---|---|---|---|
| Product owner | | | |
| Lead architect | | | |
| Mobile lead | | | |
| Backend lead | | | |
| Finance / compliance | | | |
| Legal | | | |
