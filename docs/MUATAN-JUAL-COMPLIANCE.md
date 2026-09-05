# Muatan Jual — Compliance Document

**Status: `NOT_READY`.** This document exists to be completed with professional advice, not to substitute for it.

**Muatan Jual is a CORE KasihKirim capability** (accepted 2026-09-04). It is
built and gated, never shelved: BUILD → TEST → COMPLIANCE GATE → ACTIVATE.
Production activation depends on the compliance lifecycle in §12 together with
the category and seller controls in §9 and §2.2 — not on a code change.

**Verification status: the gate implementation has NOT been executed.** The
`fn_marketplace_gate()` behaviour described in §12, and the 11 assertions in
`supabase/tests/07_compliance.test.sql`, are written and statically reviewed
only. See `IMPLEMENTATION-GAP-REPORT.md` §0a. No claim in this document about
what the system *does at runtime* has been demonstrated.

**This is not legal advice.** I am not a lawyer and hold no Malaysian legal qualification. Every statement below is either (a) a description of what the system does, which is verifiable from the code, or (b) a **question to put to counsel**, marked `LEGAL REVIEW REQUIRED`. Nothing here should be relied on as a statement of Malaysian or Sabah law.

Owner: KasihKirim Sdn Bhd (or successor entity — see §2)
Gate: `compliance_status` must reach `PRODUCTION_ACTIVE` before any customer can transact. Enforced in the database, not the app. See §12.

---

## 1. Business model

Muatan Jual is **Sabah-wide in scope** — sellers, products and pickup locations throughout Sabah, with per-district availability driven by `service_areas` configuration. Beluran/Paitan/KK are the initial pilot locations only.

Muatan Jual lets a verified seller list goods for sale, and lets KasihKirim's existing carrier network fulfil the delivery. It reuses the identity, trip, matching, capacity, tracking, POD, ledger, notification and audit systems already built. It is **not** a separate platform.

```
SELLER lists product
   │  (category eligibility + seller eligibility checked server-side)
   ▼
CUSTOMER browses → cart → checkout → PAYMENT INTENT
   │
   ▼  provider redirect / DuitNow QR
PROVIDER → VERIFIED WEBHOOK → order marked PAID → escrow credited
   │
   ▼
SELLER prepares → CARRIER matched from existing trip pool
   │
   ▼
PICKUP (QR/OTP proof) → TRANSPORT → DELIVERY (QR/OTP proof)
   │
   ▼
CUSTOMER confirms receipt → SETTLEMENT → seller payable, carrier payable,
                                        platform commission, promoter share
```

Distinct from the two flows already built:

| Flow | Who owns the goods | Who sets price | Who bears stock risk |
|---|---|---|---|
| **Kirim BELI** | Nobody — bought on request | Market, capped by requester budget | Requester (within cap) |
| **Kirim HANTAR** | The sender | n/a | Sender |
| **Muatan Jual** | **The seller** | **The seller** | **The seller** |

---

## 2. Role of each party

### 2.1 KasihKirim

Operates the platform: listing, discovery, matching, payment instruction, delivery, settlement, dispute handling.

**Intended position:** KasihKirim is a **marketplace operator and logistics provider**, not the seller of the goods.

`LEGAL REVIEW REQUIRED` — confirm this characterisation holds, given that KasihKirim:
- holds customer funds in escrow before releasing to the seller (see §8),
- sets and deducts commission,
- controls the delivery and the proof of delivery,
- and, in the Kirim BELI flow, has carriers purchasing goods on a customer's behalf.

The combination may attract obligations that a pure intermediary would not have. This needs an answer before activation, because it determines who is liable to the consumer.

### 2.2 Seller

The **seller of record**. Owns the goods, sets the price, bears stock risk, and is responsible for product legality, quality, description accuracy and any category-specific permits.

`LEGAL REVIEW REQUIRED` — what a seller must hold before listing, by category. Most rural sellers will hold **no business registration at all**. Confirm whether an unregistered individual may lawfully sell through a marketplace, and under what value or frequency threshold, if any.

### 2.3 Carrier

Provides transport. In Muatan Jual the carrier does **not** own the goods and does not set the price — unlike the carrier-owned stock model in `ADDENDUM-COMMERCE.md` §5, which is a separate question.

`LEGAL REVIEW REQUIRED` — carriage of goods for reward is licensed. In Sabah this sits with the **Commercial Vehicle Licensing Board (CVLB)**, not APAD. Courier services may separately engage the **MCMC** under the Postal Services Act 2012. Determine which, if either, applies to a community carrier making an already-planned journey.

### 2.4 Promoter (Kongsi & Untung)

Earns a share of **platform commission** for an attributed sale. Never a share of the seller's or carrier's proceeds.

`LEGAL REVIEW REQUIRED` — disclosure obligations for paid promotion, and whether promoter earnings are business income requiring the promoter to register.

---

## 3. Payment flow

Money never moves on the client's word. Enforced by `internal.fn_apply_payment_event`.

```
CUSTOMER → payment-intent (Edge Function)
         → PROVIDER hosted checkout / DuitNow QR
         → PROVIDER webhook (HMAC-verified, raw body, insert-first dedupe)
         → internal.payments status transition, precedence-guarded
         → internal.ledger_entries (double-entry, balanced at COMMIT)
         → escrow held
         → recipient confirms receipt
         → settlement split
```

No card data touches KasihKirim systems — hosted checkout only.

`LEGAL REVIEW REQUIRED` — **this is the single largest open item.** See §8.

---

## 4. Inventory ownership

The seller owns the stock. KasihKirim never takes title.

Server-controlled, per requirement 11:

| Field | Table |
|---|---|
| Available / reserved / sold | `public.inventory` |
| Movement log (append-only) | `public.inventory_movements` |
| Reservation with TTL | Created at checkout, released on failure or expiry |
| Overselling prevention | `CHECK (reserved <= on_hand)` plus row lock |

The client is never trusted for stock. A reservation is a database transaction, not a UI state.

---

## 5. Commission

Server-side only, from `internal.commission_rules`. The Android app holds no rates and no formula.

| Context | Basis | Rate | Note |
|---|---|---|---|
| Kirim (BELI/HANTAR) | Order total | 25 % | Founder-confirmed, deck slide 07 |
| Muatan Jual — goods | Goods subtotal | **Pending** | See §5.1 |
| Muatan Jual — delivery | Delivery fee | 25 % | Normal service rate |
| Promoter | Share of platform commission | 25 %, capped RM 10 | Never reduces seller or carrier proceeds |

### 5.1 `DECISION REQUIRED` — Muatan Jual goods commission

The seller-owned model has different economics from the carrier-owned model analysed in `ADDENDUM-COMMERCE.md` §2.1. A rate must be set commercially before activation. It is a row in `commission_rules` with an `effective_from`, not a code change.

---

## 6. Refunds

Every refund is authorised, idempotent, ledger-backed and auditable (`internal.fn_refund`).

| Scenario | Goods | Delivery fee | Commission |
|---|---|---|---|
| Full refund before dispatch | Full | Full | Reversed |
| Stock unavailable after payment | Full | Full | Reversed |
| Seller cancellation | Full | Full | Reversed + seller penalty |
| Delivery failure (carrier fault) | Full | Full | Reversed, carrier not paid |
| Customer refuses on delivery | Full | **Retained** | Retained |
| Damaged / wrong item | Per dispute outcome | Per outcome | Proportionate |
| Partial quantity shortfall | Pro-rata | Retained | Pro-rata |

**Promoter commission reverses with the sale.** `promotion_attributions.status = 'REVERSED'` and a reversing ledger transaction — never an edit to the original entry.

`LEGAL REVIEW REQUIRED` — minimum refund rights under the Consumer Protection Act 1999 and whether the table above meets or falls short of them.

---

## 7. Consumer protection

`LEGAL REVIEW REQUIRED` on all of the following.

- **Consumer Protection (Electronic Trade Transactions) Regulations 2012** — an online marketplace must disclose seller identity, business registration and contact details, and retain transaction records. Most rural sellers hold no registration. Determine what must be displayed when a seller is an unregistered individual.
- **Consumer Protection Act 1999** — implied guarantees as to quality and description; who bears them when the platform is not the seller.
- **Weights and Measures Act 1972** — goods sold by weight (fish, produce — the core catalogue) may require verified measuring instruments. **This is a live issue for a platform selling by the kilogram.**
- **Tribunal for Consumer Claims** — jurisdiction and the platform's exposure.
- Advertising and pricing display requirements.

---

## 8. Payment and escrow — the blocking item

KasihKirim holds customer funds between payment and delivery confirmation. The pitch deck markets this as a headline feature: *"Bayaran dipegang platform secara lalai."*

`LEGAL REVIEW REQUIRED` — **blocking. Nothing in Muatan Jual or prepaid Kirim can activate until this is answered.**

Questions for counsel:
1. Does holding customer funds pending delivery constitute a regulated payment or e-money activity under the **Financial Services Act 2013**, requiring Bank Negara Malaysia approval?
2. If so, can the obligation be discharged by having a **licensed payment provider hold the funds** while KasihKirim only instructs the split? The ledger is deliberately designed as a *record of claims* rather than a wallet, to make this structure available.
3. Does the Kirim BELI flow — where a carrier spends a customer's escrowed money on a third-party purchase — change the analysis?
4. Trust-account or segregation requirements, if any.
5. Whether COD-only operation avoids the issue entirely. **The pilot is designed COD-first for exactly this reason.**

---

## 9. Product restrictions

Configurable per category, changeable by compliance **without an Android release** (requirement 18).

| Status | Meaning |
|---|---|
| `NORMAL` | Sellable by any approved seller |
| `APPROVAL_REQUIRED` | Each listing individually reviewed before publication |
| `LICENCE_REQUIRED` | Seller must hold a valid, unexpired licence for the category |
| `RESTRICTED` | Both approval and licence; quantity and value caps apply |
| `PROHIBITED` | Cannot be listed under any circumstances |

### 9.1 Sabah-specific categories requiring determination

`LEGAL REVIEW REQUIRED` on each. **Do not assume a Peninsular rule applies** — Sabah administers several of these through its own departments and enactments.

| Category | Likely authority | Question |
|---|---|---|
| Fresh fish, prawns, shellfish | Sabah Department of Fisheries; Food Act 1983 | Licence to sell? Cold-chain requirements? Size/season limits? |
| Fresh produce, fruit | Sabah Department of Agriculture | Pesticide residue, grading, inter-district movement |
| **Live poultry, livestock** | **Sabah Dept of Veterinary Services & Animal Industry** | Movement permits between districts; biosecurity. The deck illustrates *ayam hidup*. |
| Processed / packaged food | Food Act 1983, Food Regulations 1985; state health | Labelling, food-handler training, premises registration |
| Wild honey, rattan, gaharu, forest produce | **Sabah Forestry Department** | Forest produce licence; likely `LICENCE_REQUIRED` |
| Any wildlife-derived product | **Sabah Wildlife Conservation Enactment 1997** | Almost certainly `PROHIBITED`. Serious criminal exposure. |
| Handicraft, textiles | — | Likely `NORMAL` |
| Traditional / herbal preparations | NPRA | Product registration; likely `RESTRICTED` |
| Alcohol, tobacco, vape | Excise; Control of Tobacco Product Regs | Likely `PROHIBITED` on-platform |
| Medicines, supplements | Poisons Act 1952; NPRA | Likely `PROHIBITED` on-platform |
| Firearms, weapons, ammunition | Arms Act 1960 | `PROHIBITED` |
| Controlled substances | Dangerous Drugs Act 1952 | `PROHIBITED` |

Launch position, pending advice: **only `kraf` (handicraft) as `NORMAL`.** Everything else starts `APPROVAL_REQUIRED` or higher until counsel confirms otherwise. It is cheaper to open a category later than to unwind an illegal sale.

---

## 10. Tax

`LEGAL REVIEW REQUIRED`.

1. **SST** — is platform commission a taxable service? Registration threshold and timing.
2. **Seller tax status** — sellers are likely below any threshold individually, but the platform may have reporting obligations.
3. **E-invoicing (LHDN MyInvois)** — applicability to platform commission, seller settlements, carrier earnings and promoter payouts. Phased mandate; confirm KasihKirim's date.
4. **Record retention** — 7 years assumed; confirm. The ledger is append-only and designed for this.
5. **Carrier and promoter income** — business income versus casual income; withholding or reporting duties.

---

## 11. Local authority

`LEGAL REVIEW REQUIRED`.

Sabah local government operates under the **Local Government Ordinance 1961 (Sabah)**, and trading licences are issued by the relevant local authority — for the pilot corridor, **Majlis Daerah Beluran**; for the city, **Dewan Bandaraya Kota Kinabalu**.

1. Does KasihKirim require a trading or business licence in each district where it operates?
2. Do sellers require premises or hawker licences?
3. Do **pickup points and agent hubs** — physical locations where goods are held — require their own licence or health approval?
4. Is a separate licence needed per district as the service area expands?

---

## 12. Activation gates

Muatan Jual is **built, tested, and gated** — not disabled and abandoned. The gate is enforced in the database so that no Android release can bypass it.

```
compliance_status:
  NOT_READY → LEGAL_REVIEW → LICENSING_IN_PROGRESS → LICENSED
            → APPROVED_FOR_PILOT → PRODUCTION_ACTIVE
            (→ SUSPENDED at any point)
```

Four independent flags, so onboarding can open before checkout does:

| Flag | Opens |
|---|---|
| `muatan_jual_enabled` | Master switch |
| `muatan_jual_seller_onboarding_enabled` | Seller applications and document collection |
| `muatan_jual_category_marketplace_enabled` | Category-level browse |
| `muatan_jual_checkout_enabled` | **Customer money movement** |

A customer can transact only when `compliance_status = 'PRODUCTION_ACTIVE'` **and** `muatan_jual_enabled` **and** `muatan_jual_checkout_enabled` **and** the category is active and not prohibited **and** the seller is `ACTIVE` with an unexpired licence where required.

All five are checked by `internal.fn_marketplace_gate()`. It is called by every marketplace RPC, and a failure raises rather than returning empty — silent failure would look like a bug and invite someone to "fix" it.

---

## 13. Activation checklist

Per requirement 21. All seventeen, evidenced, before `PRODUCTION_ACTIVE`.

- [ ] 1. Company structure confirmed
- [ ] 2. Required licences identified — §7, §9, §11
- [ ] 3. Required licences obtained
- [ ] 4. Product categories approved and configured
- [ ] 5. Seller terms completed
- [ ] 6. Customer terms completed
- [ ] 7. Refund policy completed — §6
- [ ] 8. Privacy and PDPA requirements completed
- [ ] 9. Payment flow tested (sandbox, then live micro-transaction)
- [ ] 10. Settlement tested — reconciliation clean 30 days
- [ ] 11. Dispute process tested
- [ ] 12. Admin controls tested — maker/checker on payouts
- [ ] 13. Audit logging tested
- [ ] 14. Financial reconciliation tested
- [ ] 15. Security review passed — `SECURITY.md` §13
- [ ] 16. Pilot completed — Beluran/Paitan/KK initial pilot locations
- [ ] 17. Formal management approval, minuted

**§8 blocks items 9, 10 and 17.** Resolve it first; the rest can proceed in parallel.

---

## 14. Open items register

| ID | Item | Blocks | Owner |
|---|---|---|---|
| **MJ-01** | Escrow vs BNM — §8 | Everything monetary | Counsel |
| MJ-02 | Marketplace operator characterisation — §2.1 | Liability model | Counsel |
| MJ-03 | Unregistered individual sellers — §2.2, §7 | Seller onboarding | Counsel |
| MJ-04 | Category-by-category determination — §9 | Catalogue scope | Counsel + compliance |
| MJ-05 | Carrier licensing, CVLB/MCMC — §2.3 | All delivery | Counsel |
| MJ-06 | Local authority licences — §11 | Per-district activation | Counsel |
| MJ-07 | SST and MyInvois — §10 | Settlement reporting | Tax adviser |
| MJ-08 | Weights and Measures — §7 | Selling by kg | Counsel |
| MJ-09 | Goods commission rate — §5.1 | Pricing | Management |
| MJ-10 | Consumer refund minimums — §6 | Refund policy | Counsel |

---

## 15. Change log

| Date | Change | By |
|---|---|---|
| — | Created. Status `NOT_READY`. | Engineering |

Every `compliance_status` transition must be recorded here **and** in `audit.audit_logs`, with the evidence relied on.
