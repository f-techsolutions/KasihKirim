-- ============================================================================
-- KasihKirim — seed.sql
-- Beluran <-> Kota Kinabalu launch corridor and all reference data.
-- ============================================================================

-- ── Categories (deck-confirmed) ─────────────────────────────────────────────
INSERT INTO ref.categories (slug,name_ms,name_en,default_handling,sort_order,icon) VALUES
  ('sayur',     'Sayur',      'Vegetables', '{PERISHABLE}',            1,'🥬'),
  ('buah',      'Buah',       'Fruit',      '{PERISHABLE}',            2,'🍌'),
  ('hasil-laut','Hasil Laut', 'Seafood',    '{PERISHABLE,COLD_CHAIN}', 3,'🦐'),
  ('kraf',      'Kraf',       'Handicraft', '{FRAGILE}',               4,'🧺'),
  ('lain-lain', 'Lain-lain',  'Other',      '{}',                      5,'📦')
ON CONFLICT (slug) DO NOTHING;

-- ── Route nodes: the Beluran -> KK corridor via Telupid ─────────────────────
INSERT INTO ref.route_nodes (name,node_type,district,geog,is_major) VALUES
  ('Kota Kinabalu',   'bandar',  'Kota Kinabalu', ST_Point(116.0735,5.9804)::geography, true),
  ('Sepanggar',       'pekan',   'Kota Kinabalu', ST_Point(116.1147,6.0333)::geography, false),
  ('Kg Kepayan Baru', 'kampung', 'Kota Kinabalu', ST_Point(116.0900,5.9200)::geography, false),
  ('Tuaran',          'pekan',   'Tuaran',        ST_Point(116.2264,6.1775)::geography, true),
  ('Tamparuli',       'junction','Tuaran',        ST_Point(116.2500,6.1500)::geography, true),
  ('Ranau',           'pekan',   'Ranau',         ST_Point(116.6667,5.9500)::geography, true),
  ('Kg Toboh',        'kampung', 'Ranau',         ST_Point(116.6400,5.9700)::geography, false),
  ('Telupid',         'junction','Telupid',       ST_Point(117.1333,5.6333)::geography, true),
  ('Beluran',         'pekan',   'Beluran',       ST_Point(117.5333,5.8667)::geography, true),
  ('Kg Muasnad',      'kampung', 'Beluran',       ST_Point(117.5100,5.8900)::geography, false)
ON CONFLICT DO NOTHING;

-- ── Route edges (bidirectional). Distances are CURATED — they feed pricing. ──
DO $$
DECLARE
  pairs TEXT[][] := ARRAY[
    ['Kota Kinabalu','Tuaran','34','40','sealed'],
    ['Tuaran','Tamparuli','12','15','sealed'],
    ['Tamparuli','Ranau','55','75','sealed'],
    ['Ranau','Telupid','75','95','sealed'],
    ['Telupid','Beluran','90','120','sealed'],
    ['Kota Kinabalu','Sepanggar','14','20','sealed'],
    ['Kota Kinabalu','Kg Kepayan Baru','9','15','sealed'],
    ['Ranau','Kg Toboh','8','15','gravel'],
    ['Beluran','Kg Muasnad','6','15','gravel']
  ];
  p TEXT[]; a UUID; b UUID;
BEGIN
  FOREACH p SLICE 1 IN ARRAY pairs LOOP
    SELECT id INTO a FROM ref.route_nodes WHERE name=p[1];
    SELECT id INTO b FROM ref.route_nodes WHERE name=p[2];
    INSERT INTO ref.route_edges (from_node_id,to_node_id,distance_km,typical_minutes,road_quality,min_vehicle_type)
    VALUES (a,b,p[3]::numeric,p[4]::int,p[5],
            CASE WHEN p[5]='gravel' THEN 'CAR' ELSE 'MOTORCYCLE' END::ref.vehicle_type)
    ON CONFLICT DO NOTHING;
    INSERT INTO ref.route_edges (from_node_id,to_node_id,distance_km,typical_minutes,road_quality,min_vehicle_type)
    VALUES (b,a,p[3]::numeric,p[4]::int,p[5],
            CASE WHEN p[5]='gravel' THEN 'CAR' ELSE 'MOTORCYCLE' END::ref.vehicle_type)
    ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

-- ── Distance matrix ─────────────────────────────────────────────────────────
-- internal.fn_rebuild_distance_matrix() is defined in migration
-- 0008_sabah_wide_geography.sql (section 5a), not here: it is permanent
-- infrastructure, and a definition in this file cannot be called from this
-- file because the CLI batches seed statements.

SELECT internal.fn_rebuild_distance_matrix();
-- Beluran -> Kota Kinabalu should now be ~266 km => band 'long_haul'.

-- ── Communities ─────────────────────────────────────────────────────────────
INSERT INTO public.communities (name,type,district,geog,node_id)
SELECT n.name,
       CASE n.node_type WHEN 'bandar' THEN 'bandar' WHEN 'pekan' THEN 'pekan' ELSE 'kampung' END,
       n.district, n.geog, n.id
FROM ref.route_nodes n
WHERE n.name IN ('Kg Kepayan Baru','Beluran','Kg Muasnad','Ranau','Kg Toboh','Kota Kinabalu')
ON CONFLICT DO NOTHING;

-- ── Pricing v1: BANDED distance, not per-km. ────────────────────────────────
-- Per-km pricing gave RM120 on this corridor against a RM50 deck order value.
INSERT INTO internal.pricing_rules (version,effective_from,params) VALUES (1, now(), '{
  "base_fare_sen": 500,
  "per_kg_sen": 150,
  "included_kg": 1,
  "volumetric_divisor": 5000,
  "corridor_band_km":  {"local": 25, "district": 80, "regional": 150},
  "corridor_band_sen": {"local": 0, "district": 300, "regional": 500, "long_haul": 800},
  "cod_handling_sen": 100,
  "handling_surcharge_sen": {
    "FRAGILE": 200, "COLD_CHAIN": 300, "LIVE_ANIMAL": 500,
    "OVERSIZED": 600, "PERISHABLE": 100, "LIQUID": 200, "DOCUMENTS": 0, "HALAL_SEPARATE": 100
  },
  "max_budget_cap_sen": 25000
}'::jsonb) ON CONFLICT (version) DO NOTHING;

-- ── Commission: 25% of order total (deck slide 07, founder-confirmed) ───────
INSERT INTO internal.commission_rules (party,basis,rate_bps,max_commission_sen,effective_from)
VALUES ('platform','order_total',2500,NULL,now());

-- ── System ledger accounts ──────────────────────────────────────────────────
INSERT INTO internal.ledger_accounts (account_code,account_class,is_system) VALUES
  ('GATEWAY_CLEARING','ASSET',true),
  ('BANK_OPERATING','ASSET',true),
  ('ESCROW_HELD_GOODS','LIABILITY',true),
  ('ESCROW_HELD_DELIVERY','LIABILITY',true),
  ('PAYOUT_PAYABLE','LIABILITY',true),
  ('AGENT_PAYABLE','LIABILITY',true),
  ('TAX_PAYABLE','LIABILITY',true),
  ('PLATFORM_COMMISSION','REVENUE',true),
  ('PROMO_EXPENSE','EXPENSE',true),
  ('GATEWAY_FEES','EXPENSE',true),
  ('WRITE_OFF','EXPENSE',true)
ON CONFLICT (account_code) DO NOTHING;

-- ── Delivery state machine ──────────────────────────────────────────────────
INSERT INTO ref.delivery_transition_rules
  (from_status,event,to_status,allowed_roles,applies_to_types,requires_proof,proof_leg) VALUES
  ('MATCHED','START_PROCUREMENT','PROCURING','{carrier}','{BELI}',false,NULL),
  ('PROCURING','RECORD_PURCHASE','AWAITING_PICKUP','{carrier}','{BELI}',false,NULL),
  ('PROCURING','RAISE_VARIANCE','PROCURING','{carrier}','{BELI}',false,NULL),
  ('PROCURING','PROCUREMENT_FAILED','PROCUREMENT_FAILED','{carrier,admin_ops}','{BELI}',false,NULL),
  ('MATCHED','GO_TO_PICKUP','AWAITING_PICKUP','{carrier}','{HANTAR,PASARAN}',false,NULL),
  ('AWAITING_PICKUP','CONFIRM_PICKUP','PICKED_UP','{carrier,agent}','{BELI,HANTAR,PASARAN}',true,'pickup'),
  ('AWAITING_PICKUP','REPORT_FAILURE','FAILED_PICKUP','{carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('PICKED_UP','DEPART','IN_TRANSIT','{carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('IN_TRANSIT','ARRIVE_HUB','AT_HUB','{carrier,agent}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('AT_HUB','LEAVE_HUB','IN_TRANSIT','{carrier,agent}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('IN_TRANSIT','START_DELIVERY','OUT_FOR_DELIVERY','{carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('OUT_FOR_DELIVERY','CONFIRM_DELIVERY','DELIVERED','{carrier,agent}','{BELI,HANTAR,PASARAN}',true,'dropoff'),
  ('OUT_FOR_DELIVERY','REPORT_FAILURE','FAILED_DELIVERY','{carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('FAILED_DELIVERY','RETRY','OUT_FOR_DELIVERY','{carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('FAILED_DELIVERY','RETURN','RETURNING','{carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('RETURNING','CONFIRM_RETURN','RETURNED','{carrier,agent}','{BELI,HANTAR,PASARAN}',true,'dropoff'),
  ('DELIVERED','CONFIRM_RECEIPT','COMPLETED','{customer,agent}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('DELIVERED','AUTO_SETTLE','COMPLETED','{admin_ops}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('DELIVERED','OPEN_DISPUTE','DISPUTED','{customer,seller,carrier}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('MATCHED','CANCEL','CANCELLED','{customer,carrier,admin_ops}','{BELI,HANTAR,PASARAN}',false,NULL),
  ('AWAITING_PICKUP','CANCEL','CANCELLED','{customer,carrier,admin_ops}','{BELI,HANTAR,PASARAN}',false,NULL)
ON CONFLICT (from_status,event) DO NOTHING;

-- ── Badges (deck: profile shows Lencana, starting with Kirim Pertama) ───────
INSERT INTO ref.badge_definitions (slug,name_ms,name_en,icon,rule,sort_order) VALUES
  ('kirim-pertama','Kirim Pertama','First Kirim','🌱','{"kirim_completed":1}',1),
  ('kirim-sepuluh','10 Kirim','10 Kirim','📦','{"kirim_completed":10}',2),
  ('dipercayai','Dipercayai','Trusted','🤝','{"rating_avg":4.5,"rating_count":10}',3),
  ('sokong-kampung','Sokong Kampung','Village Supporter','🏡','{"communities":2}',4),
  ('pembawa-setia','Pembawa Setia','Loyal Carrier','🚚','{"deliveries_completed":25}',5)
ON CONFLICT (slug) DO NOTHING;

-- ── Voucher campaign: 12-month launch programme, hard budget ceiling ────────
-- Deck: vouchers funded from the RM500k raise. ck_campaign_budget stops it dead
-- when the ceiling is reached — the programme cannot overspend.
INSERT INTO public.voucher_campaigns
  (code_prefix,name,discount_type,discount_value,max_discount_sen,min_order_sen,
   applies_to,budget_ceiling_sen,per_user_limit,starts_at,ends_at)
VALUES ('KASIH','Baucar Pelancaran 12 Bulan','fixed',500,500,2000,
        '{BELI,HANTAR}',5000000,3,now(),now()+INTERVAL '12 months');

-- ── Scheduled jobs (skipped when pg_cron is unavailable) ────────────────────
DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    RAISE NOTICE 'pg_cron not installed - skipping job scheduling.';
    RETURN;
  END IF;

  PERFORM cron.schedule('expire_capacity_holds','* * * * *',
    $j$UPDATE public.trip_reservations SET status='RELEASED', released_at=now()
       WHERE status='HELD' AND expires_at < now()$j$);

  PERFORM cron.schedule('expire_variances','* * * * *',
    $j$UPDATE public.price_variances SET status='TIMED_OUT', responded_at=now()
       WHERE status='PENDING' AND expires_at < now()$j$);

  PERFORM cron.schedule('settle_delivered','*/10 * * * *',
    $j$SELECT internal.fn_settle_delivery(id) FROM public.deliveries
       WHERE status='DELIVERED' AND settlement_due_at < now()$j$);

  PERFORM cron.schedule('reconcile_ledger','0 2 * * *',
    $j$INSERT INTO internal.job_runs (job_name,ended_at,outcome,detail)
       SELECT 'reconcile_ledger', now(),
              CASE WHEN COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen
                                          ELSE -amount_sen END),0)=0
                   THEN 'BALANCED' ELSE 'VARIANCE' END,
              jsonb_build_object('variance_sen',
                COALESCE(SUM(CASE WHEN direction='DEBIT' THEN amount_sen
                                  ELSE -amount_sen END),0))
       FROM internal.ledger_entries$j$);

  PERFORM cron.schedule('prune_tracking','0 3 * * *',
    $j$DELETE FROM public.delivery_tracking_points
       WHERE recorded_at < now() - INTERVAL '30 days'$j$);

  PERFORM cron.schedule('prune_idempotency','0 * * * *',
    $j$DELETE FROM internal.idempotency_keys WHERE expires_at < now()$j$);
END $cron$;

-- ============================================================================
-- 0007 — Sabah geography. Beluran is DATA, not architecture (§22).
-- Activating another district is an UPDATE to service_areas.status.
-- ============================================================================
INSERT INTO ref.regions (code, name) VALUES ('SBH','Sabah')
ON CONFLICT (code) DO NOTHING;

-- All five Sabah divisions.
INSERT INTO ref.divisions (region_id, code, name)
SELECT r.id, v.code, v.name
FROM ref.regions r, (VALUES
  ('SBH-DIV-WC','West Coast'), ('SBH-DIV-IN','Interior'),
  ('SBH-DIV-KD','Kudat'),      ('SBH-DIV-SD','Sandakan'),
  ('SBH-DIV-TW','Tawau')
) AS v(code,name) WHERE r.code='SBH'
ON CONFLICT (code) DO NOTHING;

-- ALL 27 Sabah districts, from day one (§2). PLANNED by default; the pilot
-- three are PILOT. Opening any other is an admin UPDATE to status, never a
-- release. Beluran is one district among 27 — not the root of the geography.
INSERT INTO ref.districts (region_id, division_id, code, name, local_authority,
                           status, terrain_profile)
SELECT r.id, dv.id, d.code, d.name, d.la, d.st::ref.district_status, d.terrain::text[]
FROM (VALUES
  -- West Coast
  ('SBH-KK','Kota Kinabalu','SBH-DIV-WC','Dewan Bandaraya Kota Kinabalu','PILOT','{urban,coastal}'),
  ('SBH-KBD','Kota Belud','SBH-DIV-WC','Majlis Daerah Kota Belud','PLANNED','{rural,coastal}'),
  ('SBH-PPR','Papar','SBH-DIV-WC','Majlis Daerah Papar','PLANNED','{rural,coastal}'),
  ('SBH-PNP','Penampang','SBH-DIV-WC','Majlis Daerah Penampang','PLANNED','{urban}'),
  ('SBH-PTT','Putatan','SBH-DIV-WC','Majlis Daerah Putatan','PLANNED','{urban}'),
  ('SBH-RNU','Ranau','SBH-DIV-WC','Majlis Daerah Ranau','PLANNED','{rural,highland}'),
  ('SBH-TRN','Tuaran','SBH-DIV-WC','Majlis Daerah Tuaran','PLANNED','{rural,coastal}'),
  -- Interior
  ('SBH-BFT','Beaufort','SBH-DIV-IN','Majlis Daerah Beaufort','PLANNED','{rural,river}'),
  ('SBH-KGU','Keningau','SBH-DIV-IN','Majlis Daerah Keningau','PLANNED','{rural,highland}'),
  ('SBH-KPY','Kuala Penyu','SBH-DIV-IN','Majlis Daerah Kuala Penyu','PLANNED','{rural,coastal}'),
  ('SBH-NBW','Nabawan','SBH-DIV-IN','Majlis Daerah Nabawan','PLANNED','{remote,forest}'),
  ('SBH-SPT','Sipitang','SBH-DIV-IN','Majlis Daerah Sipitang','PLANNED','{rural,coastal}'),
  ('SBH-TBN','Tambunan','SBH-DIV-IN','Majlis Daerah Tambunan','PLANNED','{rural,highland}'),
  ('SBH-TNM','Tenom','SBH-DIV-IN','Majlis Daerah Tenom','PLANNED','{rural,highland}'),
  -- Kudat
  ('SBH-KMR','Kota Marudu','SBH-DIV-KD','Majlis Daerah Kota Marudu','PLANNED','{rural,coastal}'),
  ('SBH-KDT','Kudat','SBH-DIV-KD','Majlis Daerah Kudat','PLANNED','{rural,coastal,island}'),
  ('SBH-PTS','Pitas','SBH-DIV-KD','Majlis Daerah Pitas','PLANNED','{remote,coastal}'),
  -- Sandakan
  ('SBH-BLR','Beluran','SBH-DIV-SD','Majlis Daerah Beluran','PILOT','{rural,coastal,river}'),
  ('SBH-KNB','Kinabatangan','SBH-DIV-SD','Majlis Daerah Kinabatangan','PLANNED','{remote,river,forest}'),
  ('SBH-SDK','Sandakan','SBH-DIV-SD','Majlis Perbandaran Sandakan','PLANNED','{urban,coastal}'),
  ('SBH-TLP','Telupid','SBH-DIV-SD','Majlis Daerah Telupid','PLANNED','{rural,forest}'),
  ('SBH-TGD','Tongod','SBH-DIV-SD','Majlis Daerah Tongod','PLANNED','{remote,forest}'),
  -- Tawau
  ('SBH-KLB','Kalabakan','SBH-DIV-TW','Majlis Daerah Kalabakan','PLANNED','{remote,forest}'),
  ('SBH-KNK','Kunak','SBH-DIV-TW','Majlis Daerah Kunak','PLANNED','{rural,coastal}'),
  ('SBH-LD','Lahad Datu','SBH-DIV-TW','Majlis Daerah Lahad Datu','PLANNED','{urban,coastal}'),
  ('SBH-SMP','Semporna','SBH-DIV-TW','Majlis Daerah Semporna','PLANNED','{coastal,island}'),
  ('SBH-TWU','Tawau','SBH-DIV-TW','Majlis Perbandaran Tawau','PLANNED','{urban,coastal}')
) AS d(code,name,div,la,st,terrain)
CROSS JOIN ref.regions r
JOIN ref.divisions dv ON dv.code = d.div
WHERE r.code='SBH'
ON CONFLICT (code) DO NOTHING;

-- Paitan is a SUB-DISTRICT (daerah kecil) of Beluran, not a district in its
-- own right, and certainly not the root of the geography (§10).
-- LOCAL VERIFICATION REQUIRED: Sabah administrative boundaries change; confirm
-- Paitan's current status with the state authority before go-live.
INSERT INTO ref.districts (region_id, division_id, parent_district_id, is_sub_district,
                           code, name, local_authority, status, terrain_profile)
SELECT r.id, b.division_id, b.id, true,
       'SBH-BLR-PTN','Paitan','Majlis Daerah Beluran','PILOT','{remote,coastal,river}'
FROM ref.regions r, ref.districts b
WHERE r.code='SBH' AND b.code='SBH-BLR'
ON CONFLICT (code) DO NOTHING;

-- Every district gets a service area. Three are PILOT; the rest PLANNED.
INSERT INTO public.service_areas (district_id, name, status, supports_cod,
        supports_prepaid, supports_marketplace, supported_transport, terrain, activated_at)
SELECT d.id, d.name,
  CASE d.status WHEN 'PILOT' THEN 'PILOT' ELSE 'PLANNED' END::ref.service_area_status,
  true, false, false,
  CASE WHEN 'river' = ANY(d.terrain_profile) OR 'island' = ANY(d.terrain_profile)
       THEN '{MOTORCYCLE,CAR,PICKUP,FOURWD,VAN,BOAT}'::ref.vehicle_type[]
       ELSE '{MOTORCYCLE,CAR,PICKUP,FOURWD,VAN,LORRY}'::ref.vehicle_type[] END,
  d.terrain_profile,
  CASE WHEN d.status = 'PILOT' THEN now() END
FROM ref.districts d
ON CONFLICT (district_id, name) DO NOTHING;

-- Paitan: coastal/riverine, north of Beluran. Boat is a first-class vehicle
-- type here, not an edge case.
INSERT INTO ref.route_nodes (name, node_type, district, geog, is_major) VALUES
  ('Paitan',        'pekan',   'Paitan',  ST_Point(117.2500, 6.2167)::geography, true),
  ('Kg Sungai Paitan','kampung','Paitan', ST_Point(117.2300, 6.2400)::geography, false),
  ('Jeti Paitan',   'jetty',   'Paitan',  ST_Point(117.2450, 6.2100)::geography, false)
ON CONFLICT DO NOTHING;

DO $$
DECLARE a UUID; b UUID; p TEXT[];
  pairs TEXT[][] := ARRAY[
    ['Beluran','Paitan','78','130','gravel'],
    ['Paitan','Jeti Paitan','5','12','gravel'],
    ['Jeti Paitan','Kg Sungai Paitan','9','25','river']
  ];
BEGIN
  FOREACH p SLICE 1 IN ARRAY pairs LOOP
    SELECT id INTO a FROM ref.route_nodes WHERE name=p[1];
    SELECT id INTO b FROM ref.route_nodes WHERE name=p[2];
    INSERT INTO ref.route_edges (from_node_id,to_node_id,distance_km,typical_minutes,
                                 road_quality,min_vehicle_type)
    VALUES (a,b,p[3]::numeric,p[4]::int,p[5],
            CASE p[5] WHEN 'river' THEN 'BOAT' WHEN 'gravel' THEN 'FOURWD'
                      ELSE 'CAR' END::ref.vehicle_type)
    ON CONFLICT DO NOTHING;
    INSERT INTO ref.route_edges (from_node_id,to_node_id,distance_km,typical_minutes,
                                 road_quality,min_vehicle_type)
    VALUES (b,a,p[3]::numeric,p[4]::int,p[5],
            CASE p[5] WHEN 'river' THEN 'BOAT' WHEN 'gravel' THEN 'FOURWD'
                      ELSE 'CAR' END::ref.vehicle_type)
    ON CONFLICT DO NOTHING;
  END LOOP;
END $$;

SELECT internal.fn_rebuild_distance_matrix();

-- Backfill district_id on existing geography.
UPDATE ref.route_nodes n SET district_id = d.id
  FROM ref.districts d WHERE d.name = n.district AND n.district_id IS NULL;
UPDATE public.communities c SET district_id = d.id
  FROM ref.districts d WHERE d.name = c.district AND c.district_id IS NULL;
UPDATE public.communities c SET service_area_id = sa.id
  FROM public.service_areas sa WHERE sa.district_id = c.district_id
   AND c.service_area_id IS NULL;
