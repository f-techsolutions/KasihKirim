# KasihKirim — Addendum: Carrier Commerce

**Status: proposed, not approved.** Two decisions in §7 block implementation.

Extends [`PRD.md`](./PRD.md). Feature IDs continue the existing series.

---

## 1. What was asked

| # | Request (as given) | Name | Nature |
|---|---|---|---|
| A | *"Pembawa can ask pengirim to send more"* | **Ajak Kirim** | Capacity fill. Small, safe, high value. |
| B | *"Extra products or supplier can be promoted or sell by pengirim or pembawa"* | **Kongsi & Untung** | Referral layer. Medium. |
| C | *"Pembawa can sell the products yang dia bawa"* | **Muatan Jual** | **Structural.** Changes what a carrier legally and financially *is*. |

A and B extend the existing model. **C does not.** It should be read and decided separately from the other two.

---

## 2. Why C is structural

Everything built so far rests on one assumption: **the carrier is a service provider, never a principal.**

- In `BELI` the goods money is the *requester's*, passing through. The carrier is reimbursed **at cost** and earns a service fee.
- The carrier bears no inventory risk, sets no price, and owns nothing.
- Commission is 25 % of order total, which works precisely because the goods leg is pass-through.

Muatan Jual inverts all of it. The carrier buys with **their own capital**, sets **their own price**, and owns unsold stock. They stop being a courier and become a **trader** — the *peraih* role that already exists informally in rural Sabah.

That is a defensible product. It is also a different business with different risk, and it needs its own money model rather than reuse of the delivery one.

### 2.1 The 25 % breaks immediately

Using the deck's own example — langsat at RM 8/kg from Kg Toboh, Ranau:

```
Carrier buys 20 kg @ RM 8   = RM 160   (their own cash, at risk)
Sells in KK   20 kg @ RM 12 = RM 240
Gross margin                = RM  80

Commission at 25% of order total (RM 240)      = RM 60
  → carrier keeps RM 20 on RM 160 of capital.  Not viable.

Commission at 25% of margin (RM 80)            = RM 20
  → carrier keeps RM 60.

Commission at 10% of order total               = RM 24
  → carrier keeps RM 56.
```

The first row is not a tuning problem, it is a category error: applying a service-fee rate to a goods-resale transaction. **Muatan Jual needs its own commission basis.** See §7, Decision 1.

`commission_rules` already carries `basis`, `rate_bps` and `max_commission_sen`, so this is a data change — but it is a *decision*, not an assumption I should make.

---

## 3. Feature A — Ajak Kirim (carrier invites more cargo)

The cheapest of the three and the most strategically valuable, because it attacks the metric that decides whether carrying is worth a carrier's time.

At RM 2.50 service earnings per parcel (`ARCHITECTURE.md` §7.3a), one parcel is pointless and ten is RM 25 on fuel already burned. **Trip fill rate is the number that makes carrier supply viable.** Ajak Kirim is a direct lever on it.

### 3.1 Requirements

| ID | Requirement | Pri |
|---|---|---|
| FR-400 | A carrier with spare capacity on an `ANNOUNCED`/`BOARDING` trip can send an invite: *"Ada 30 kg kosong ke KK esok pagi. Ada apa-apa nak dikirim?"* | 1 |
| FR-401 | Audience is one of: a community, everyone who has sent with this carrier before, or a specific named person. | 1 |
| FR-402 | The invite carries the **live** remaining capacity, not a snapshot. Inviting into space that is already gone destroys trust fast. | 1 |
| FR-403 | Tapping the invite opens a pre-filled Kirim wizard with the trip pre-selected. | 1 |
| FR-404 | Rate limited: max 2 invites per trip, max 1 per recipient per 24 h. | 1 |
| FR-405 | Recipients can mute invites per carrier and globally. Delivered on the `promotions` notification channel (LOW), never `delivery_critical`. | 1 |
| FR-406 | Invites auto-expire when the trip departs or capacity fills. | 1 |
| FR-407 | **Restock ask:** a carrier can ask a specific supplier to prepare more of something they have carried before. | 2 |

### 3.2 Why the rate limits are not optional

An invite is an unsolicited push notification from one user to another, aimed at getting them to spend money. Without hard caps this becomes spam, and in a market where notifications are already fragile (`ANDROID.md` §6.2) users respond by muting the app entirely — taking `delivery_critical` with it. The cap protects the delivery channel, not just the inbox.

### 3.3 Schema

```sql
CREATE TYPE ref.invite_audience AS ENUM ('community','past_senders','specific_user');

CREATE TABLE public.capacity_invites (
  id                UUID PRIMARY KEY DEFAULT uuidv7(),
  trip_id           UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  carrier_id        UUID NOT NULL REFERENCES public.carriers(id),
  audience          ref.invite_audience NOT NULL,
  community_id      UUID REFERENCES public.communities(id),
  target_user_id    UUID REFERENCES public.profiles(id),
  message           TEXT CHECK (length(message) <= 200),
  sent_count        INT NOT NULL DEFAULT 0,
  response_count    INT NOT NULL DEFAULT 0,
  expires_at        TIMESTAMPTZ NOT NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (audience <> 'community'     OR community_id   IS NOT NULL),
  CHECK (audience <> 'specific_user' OR target_user_id IS NOT NULL)
);
-- FR-404: two invites per trip, enforced by the database not the UI.
CREATE UNIQUE INDEX ux_invite_per_trip
  ON public.capacity_invites(trip_id, audience, COALESCE(community_id, target_user_id));

CREATE TABLE public.invite_responses (
  invite_id  UUID NOT NULL REFERENCES public.capacity_invites(id) ON DELETE CASCADE,
  user_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kirim_id   UUID REFERENCES public.kirim_requests(id),
  responded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (invite_id, user_id)
);

CREATE TABLE public.restock_requests (
  id            UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id    UUID NOT NULL REFERENCES public.carriers(id),
  supplier_id   UUID NOT NULL REFERENCES public.profiles(id),
  product_id    UUID REFERENCES public.products(id),
  description   TEXT NOT NULL,
  qty_note      TEXT NOT NULL,
  needed_by     DATE,
  status        TEXT NOT NULL DEFAULT 'PENDING'
                  CHECK (status IN ('PENDING','ACCEPTED','DECLINED','EXPIRED')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**No money.** Ajak Kirim creates a normal Kirim through the existing flow. Nothing in the ledger changes.

---

## 4. Feature B — Kongsi & Untung (promotion and referral)

Anyone — pengirim, pembawa, or agent — can promote a seller's product and earn a share when it sells.

| ID | Requirement | Pri |
|---|---|---|
| FR-420 | Generate a share link/code for a product or seller. Shares to WhatsApp, which is where this market actually lives. | 2 |
| FR-421 | Attribution on first click, 7-day window, last-click-wins within it. | 2 |
| FR-422 | Promoter commission comes **out of the platform's share**, never out of the seller's or carrier's. | 2 |
| FR-423 | Self-referral blocked: promoter ≠ buyer, and shared device/phone/bank raises a risk signal. | 2 |
| FR-424 | Promoted content is labelled as such in the UI. Undisclosed paid promotion is a consumer-protection problem. | 2 |
| FR-425 | Promoter earnings appear in the same wallet and payout flow as carrier earnings. | 2 |

FR-422 matters. If promoter commission came out of the seller's cut, a kampung producer would silently earn less because a stranger shared their listing. Taking it from platform revenue keeps the incentive honest and keeps the seller's economics predictable.

```sql
CREATE TABLE public.promotions (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  promoter_id    UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  subject_type   TEXT NOT NULL CHECK (subject_type IN ('product','seller','lot')),
  subject_id     UUID NOT NULL,
  code           TEXT NOT NULL UNIQUE,
  commission_bps INT NOT NULL DEFAULT 300 CHECK (commission_bps BETWEEN 0 AND 2500),
  is_active      BOOLEAN NOT NULL DEFAULT true,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (promoter_id, subject_type, subject_id)
);

CREATE TABLE public.promotion_attributions (
  id             UUID PRIMARY KEY DEFAULT uuidv7(),
  promotion_id   UUID NOT NULL REFERENCES public.promotions(id),
  buyer_id       UUID NOT NULL REFERENCES public.profiles(id),
  order_id       UUID REFERENCES public.orders(id),
  kirim_id       UUID REFERENCES public.kirim_requests(id),
  order_total_sen BIGINT NOT NULL,
  commission_sen BIGINT NOT NULL CHECK (commission_sen >= 0),
  status         TEXT NOT NULL DEFAULT 'PENDING'
                   CHECK (status IN ('PENDING','SETTLED','REVERSED')),
  attributed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT ck_no_self_referral CHECK (true)   -- enforced by trigger, see below
);
```

```sql
-- BR-910 extension. A CHECK cannot reach another table, so this is a trigger.
CREATE OR REPLACE FUNCTION internal.tg_block_self_referral()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.promotions p
             WHERE p.id = NEW.promotion_id AND p.promoter_id = NEW.buyer_id) THEN
    RAISE EXCEPTION 'SELF_REFERRAL_BLOCKED';
  END IF;
  RETURN NEW;
END $$;
```

Settlement adds one leg, funded from platform revenue:

```
DR Platform Commission      RM 1.20
  CR Promoter Payable                RM 1.20
```

---

## 5. Feature C — Muatan Jual (carrier sells what they carry)

### 5.1 The model

A carrier buys a **stock lot**, carries it on a trip, and sells units from it. The lot is the unit of accounting: it has a cost basis, a quantity, and a life.

```
   Carrier buys 20kg langsat @ RM8  ──►  carrier_stock_lots
   (cost basis RM160, receipt photo)          │
                                              ▼
   Attaches lot to trip Ranau → KK  ──►  trip_listings (visible on Papan Kirim)
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
             Buyer orders 2kg          Buyer orders 5kg         13kg unsold
             (normal order flow)                                       │
                                                                       ▼
                                                        Carrier's loss. Not the
                                                        platform's, not escrow's.
```

### 5.2 Requirements

| ID | Requirement | Pri |
|---|---|---|
| FR-440 | A verified carrier can apply for the `seller` role. Multi-role already exists; no new identity model. | 2 |
| FR-441 | Create a stock lot: description, category, quantity, unit, **cost basis with receipt photo**, asking price, perishability window. | 2 |
| FR-442 | Attach a lot to a trip. It becomes visible on Papan Kirim to users along that corridor. | 2 |
| FR-443 | Buyers order from a lot through the **existing order flow**. No parallel checkout. | 2 |
| FR-444 | Stock decrements atomically. A lot cannot oversell — same guard pattern as trip capacity. | 2 |
| FR-445 | Perishable lots auto-delist at their window. Selling yesterday's fish is a trust event, not an inventory event. | 2 |
| FR-446 | Unsold stock is written down to the **carrier's** account. Never platform expense, never escrow. | 2 |
| FR-447 | Cost basis is **private** to the carrier and admin. Buyers see the price, not the margin. | 2 |
| FR-448 | Lot value counts against the carrier's float limit alongside COD and procurement advances. | 2 |
| FR-449 | Every listing shows the seller identity and that the carrier is the seller of record. | 2 |

### 5.3 Schema

```sql
CREATE TYPE ref.lot_status AS ENUM
  ('DRAFT','ACTIVE','SOLD_OUT','EXPIRED','WITHDRAWN','WRITTEN_OFF');

CREATE TABLE public.carrier_stock_lots (
  id               UUID PRIMARY KEY DEFAULT uuidv7(),
  carrier_id       UUID NOT NULL REFERENCES public.carriers(id) ON DELETE RESTRICT,
  seller_id        UUID NOT NULL REFERENCES public.sellers(id),
  trip_id          UUID REFERENCES public.trips(id),
  title            TEXT NOT NULL CHECK (length(title) BETWEEN 3 AND 120),
  category_id      UUID NOT NULL REFERENCES ref.categories(id),
  handling_flags   ref.handling_flag[] NOT NULL DEFAULT '{}',
  unit             TEXT NOT NULL DEFAULT 'kg',
  qty_total        NUMERIC(10,2) NOT NULL CHECK (qty_total > 0),
  qty_reserved     NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (qty_reserved >= 0),
  qty_sold         NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (qty_sold >= 0),
  -- Private: cost basis and receipt are never exposed to buyers (FR-447).
  cost_basis_sen   BIGINT NOT NULL CHECK (cost_basis_sen >= 0),
  cost_receipt_path TEXT NOT NULL,
  source_seller_id UUID REFERENCES public.sellers(id),
  price_per_unit_sen BIGINT NOT NULL CHECK (price_per_unit_sen > 0),
  photo_paths      TEXT[] NOT NULL DEFAULT '{}',
  status           ref.lot_status NOT NULL DEFAULT 'DRAFT',
  sell_by          TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Same shape as the trip capacity guard: overselling a physical lot is as
  -- unrecoverable as overbooking a truck. (BR-903 pattern)
  CONSTRAINT ck_lot_not_oversold CHECK (qty_reserved + qty_sold <= qty_total),
  -- Perishables must declare a window.
  CONSTRAINT ck_lot_perishable_window
    CHECK (NOT ('PERISHABLE' = ANY(handling_flags)) OR sell_by IS NOT NULL)
);

CREATE TABLE public.trip_listings (
  id          UUID PRIMARY KEY DEFAULT uuidv7(),
  lot_id      UUID NOT NULL REFERENCES public.carrier_stock_lots(id) ON DELETE CASCADE,
  trip_id     UUID NOT NULL REFERENCES public.trips(id) ON DELETE CASCADE,
  from_node_id UUID REFERENCES ref.route_nodes(id),
  to_node_id   UUID REFERENCES ref.route_nodes(id),
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (lot_id, trip_id)
);

-- FR-448: inventory joins COD and procurement advance under ONE limit.
ALTER TABLE public.carriers
  ADD COLUMN inventory_at_risk_sen BIGINT NOT NULL DEFAULT 0
    CHECK (inventory_at_risk_sen >= 0);

ALTER TABLE public.carriers DROP CONSTRAINT ck_carrier_exposure;
ALTER TABLE public.carriers ADD CONSTRAINT ck_carrier_exposure
  CHECK (cod_held_sen + procurement_advance_sen + inventory_at_risk_sen
         <= float_limit_sen);
```

That last change is the important one. A carrier holding RM 400 of COD cash **and** RM 300 of unsold fish is exposed for RM 700, and the platform's bad-debt exposure moves with them. One constraint, three kinds of risk.

### 5.4 Money

```
Lot purchase      (carrier's own capital — the platform does not fund it)
  DR Carrier Inventory : {id}      RM 160.00
    CR Carrier Payable : {id}                 RM 160.00

Sale of 2 kg @ RM 12 = RM 24, commission at the Muatan Jual rate
  DR Escrow Held — Delivery         RM 24.00
    CR Platform Commission                    RM  X.XX     ← Decision 1
    CR Carrier Payable : {id}                 RM 24.00 − X

Cost of goods sold (2/20 of the lot)
  DR Carrier Payable : {id}         RM 16.00
    CR Carrier Inventory : {id}                RM 16.00

Unsold 13 kg written down at expiry (FR-446)
  DR Carrier Loss : {id}            RM 104.00
    CR Carrier Inventory : {id}                RM 104.00
```

The write-down hits `Carrier Loss`, not `WRITE_OFF`. **The platform does not absorb a carrier's trading losses**, and the ledger should say so plainly rather than blurring it into platform expense.

---

## 6. Risks introduced

| # | Risk | Mitigation |
|---|---|---|
| R-1 | **Carrier capital loss.** Unsold perishables are a real cash loss for someone earning RM 2.50 a parcel. | Start with a low lot ceiling (RM 200), require completed-delivery history before unlocking, show a plain-language warning at lot creation. |
| R-2 | **Conflict of interest.** A carrier carrying a competitor's `PASARAN` order while selling their own stock has an incentive to prioritise their own. | Delivery SLA applies equally; on-time rate is measured per delivery regardless of source; lot sales are blocked while a delivery on the same trip is overdue. |
| R-3 | **Price gouging.** Captive rural buyer, single carrier on the corridor. | Publish a category price band from recent transactions; flag listings above 2σ for review. Do **not** hard-cap: a genuine scarcity price is legitimate. |
| R-4 | **Escrow ambiguity.** Platform now holds money for a carrier's own goods, deepening LGL-02. | Blocked on LGL-02 either way. |
| R-5 | **Food safety.** Selling fresh seafood and produce is regulated differently from carrying it. | LGL-13. |
| R-6 | **Invite spam kills the notification channel.** | FR-404/405 caps, enforced in the database. |
| R-7 | **Cost-basis fraud.** Overstated cost reduces margin-based commission. | Only matters under Decision 1(b). Receipt photo mandatory; rolling median per category × corridor; outliers to the risk queue. |
| R-8 | **Referral farming.** | FR-423, device/bank overlap detection, attribution reversal on refund. |

---

## 7. Decisions required

### Decision 1 — Commission basis for Muatan Jual *(blocking)*

25 % of order total does not work (§2.1). Choose one:

| Option | Mechanism | Pro | Con |
|---|---|---|---|
| **(a)** | **~10 % of order total** | Simple, ungameable, predictable | Still bites on thin-margin staples |
| (b) | 25 % of declared margin | Matches the delivery rate; fair on thin margins | Cost basis is self-declared — needs receipts and monitoring (R-7) |
| (c) | Flat fee per lot or per sale | Trivial to explain | Regressive on small sales |

**Recommendation: (a), ~10 %.** It cannot be gamed, needs no cost-basis audit, and the arithmetic in §2.1 shows it lands within a few ringgit of the margin-based option anyway. Simplicity wins when the alternative introduces a fraud surface.

### Decision 2 — Does the platform fund carrier inventory? *(blocking)*

If yes, KasihKirim is extending credit to individuals. That is a different regulated activity from holding escrow, and it stacks on top of LGL-02.

**Recommendation: no.** Carrier capital only, at launch.

### Decision 3 — Who is the seller of record?

Under the Consumer Protection (Electronic Trade Transactions) Regulations 2012, a marketplace must display seller identity and business registration. Most carriers will not hold SSM registration.

### Decision 4 — Promoter commission rate, and confirmation it comes from platform revenue (FR-422).

---

## 8. Legal additions

| ID | Concern |
|---|---|
| **LGL-13** | **Food safety.** Selling fresh produce, seafood and live poultry engages the Food Act 1983 and food-handler requirements. Live poultry movement between Sabah districts may require Department of Veterinary Services clearance. Carrying and selling are treated differently. |
| **LGL-14** | **Trading licence.** Resale for profit across district lines may require a local-authority trading licence. |
| **LGL-15** | **Seller of record.** See Decision 3. |
| **LGL-16** | **Promoter disclosure.** Paid promotion must be labelled (FR-424). |
| **LGL-17** | **Tax.** Carrier trading income is business income, distinct from service fees. Affects what the platform reports and what carriers owe. |

---

## 9. Recommended phasing

Ship in the order of risk, not the order asked.

| Phase | Feature | Gate |
|---|---|---|
| **P4a** | **Ajak Kirim** (A) | None beyond the base build. No money, no legal exposure, direct lift to the fill-rate metric. **Do this first.** |
| P4b | Restock requests (FR-407) | After A |
| P5 | Kongsi & Untung (B) | Marketplace live; promoter commission agreed |
| **P6** | **Muatan Jual (C)** | **LGL-02 resolved, LGL-13/14/15 answered, Decisions 1–3 made, 90 days of clean carrier settlement history** |

Feature A is a week of work with no new risk and it moves the number that determines whether carriers stay. Feature C is a new line of business that needs legal cover before a line of code.

---

## 10. What this does to the product

Worth stating plainly for the founders.

The deck's promise is *"ruang kosong dalam perjalanan menjadi penghantaran yang dipercayai"* — empty space becomes trusted delivery. Features A and B stay inside that sentence.

Feature C steps outside it. The carrier stops being someone who moves your parcel and becomes someone selling you fish at a price they set. That is the *peraih* role the kampung already knows, and formalising it with receipts, ratings and escrow is arguably an improvement on the informal version.

But it is a different promise, and it should be a deliberate choice rather than a feature that arrives quietly. It also creates the first situation where the platform's interests and a buyer's interests can diverge — which is exactly the dynamic the trust architecture was built to avoid.
