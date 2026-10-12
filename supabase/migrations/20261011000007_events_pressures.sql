-- Events and status: sewage, bathing, floods, pollution incidents, WFD classes, reasons-for-failure, modelled apportionment, citizen surveys.

-- ───────────── Sewage ─────────────
create table core.overflow (
  site_id             bigint primary key references core.site(id),
  company_id          bigint references ref.organisation(id),
  permit_ref          text,
  asset_type          text,
  edm_installed_on    date,
  receiving_water_raw text,                      -- free text from the company: "(S) RIVER FROME", "Tributary of Chester Burn"
  receiving_waterbody_id bigint references core.waterbody(id),
  legacy_ids          text[] not null default '{}',   -- pre-2024 ids from the old->new lookup
  bathing_water_site_id bigint references core.site(id),
  is_shellfish_water  boolean,
  attrs               jsonb not null default '{}'
);
create index on core.overflow (company_id);
create index on core.overflow (receiving_waterbody_id);
create index on core.overflow (bathing_water_site_id);
create index on core.overflow using gin (legacy_ids);

-- Current status snapshot (near-real-time feeds). One row per overflow.
create table core.overflow_status (
  site_id        bigint primary key references core.site(id),
  status         text not null check (status in ('discharging','not_discharging','offline','unknown')),
  raw_status     text,                           -- 1 / 0 / -1 / 'STATUS_ID=...' as sent
  status_since   timestamptz,
  last_event_start timestamptz,
  last_event_end   timestamptz,
  reported_at    timestamptz,                    -- the company's own LastUpdated
  fetched_at     timestamptz not null,
  source_id      bigint not null references ingest.source(id),
  run_id         bigint references ingest.run(id)
);
create index on core.overflow_status (status) where status <> 'not_discharging';
create index on core.overflow_status (source_id);
create index on core.overflow_status (run_id);

-- Event history (built by diffing snapshots; also backfilled from annual/retro data where event-level is published).
create table core.discharge_event (
  id          bigint generated always as identity primary key,
  site_id     bigint not null references core.site(id),
  started_at  timestamptz not null,
  ended_at    timestamptz,
  duration_min integer,
  basis       text not null default 'live_edm' check (basis in ('live_edm','retro_edm')),
  source_id   bigint not null references ingest.source(id),
  unique (site_id, started_at, source_id)
);
create index on core.discharge_event (started_at desc);
create index on core.discharge_event (source_id);

-- Regulatory annual aggregates. Raw strings ("#N/A", "") normalised to null; originals kept in qualifiers.
create table core.discharge_annual (
  site_id            bigint not null references core.site(id),
  year               smallint not null,
  source_id          bigint not null references ingest.source(id),
  spill_count        integer,
  total_duration_hr  numeric,
  edm_operating_pct  numeric,
  longterm_avg_spills numeric,
  has_data           boolean not null,
  qualifiers         jsonb not null default '{}',   -- investigation status, improvement plans, reasons for <90% operation, raw strings
  primary key (site_id, year, source_id)
);
create index on core.discharge_annual (year);
create index on core.discharge_annual (source_id);

create table core.permit (
  id              bigint generated always as identity primary key,
  permit_ref      text not null,
  version         integer,
  site_id         bigint references core.site(id),
  holder_id       bigint references ref.organisation(id),
  discharge_type  text,
  receiving_environment text,
  receiving_water_raw   text,
  status          text,
  issued_on       date,
  effective_on    date,
  revoked_on      date,
  source_id       bigint not null references ingest.source(id),
  attrs           jsonb not null default '{}',
  unique (source_id, permit_ref, version)
);
create index on core.permit (site_id);
create index on core.permit (holder_id);
create index on core.permit (permit_ref);

create table core.pollution_incident (
  id           bigint generated always as identity primary key,
  source_id    bigint not null references ingest.source(id),
  source_key   text not null,
  category     text,                              -- pollutant family
  pollutant    text,
  water_severity smallint check (water_severity between 1 and 4),   -- 1 major .. 4 no impact
  land_severity  smallint check (land_severity between 1 and 4),
  air_severity   smallint check (air_severity between 1 and 4),
  occurred_on  date,
  geom         geometry(Point,4326),
  waterbody_id bigint references core.waterbody(id),
  attrs        jsonb not null default '{}',
  unique (source_id, source_key)
);
create index on core.pollution_incident (waterbody_id);
create index on core.pollution_incident using gist (geom);

-- ───────────── Floods (event mode) ─────────────
create table core.flood_area (
  id        bigint generated always as identity primary key,
  code      text not null unique,
  name      text,
  kind      text check (kind in ('warning','alert')),
  geom      geometry(MultiPolygon,4326),
  source_id bigint references ingest.source(id)
);
create index on core.flood_area using gist (geom);
create index on core.flood_area (source_id);

create table core.flood_warning (
  id          bigint generated always as identity primary key,
  area_id     bigint not null references core.flood_area(id),
  severity_level smallint not null check (severity_level between 1 and 4),   -- 1 severe, 2 warning, 3 alert, 4 no longer in force
  message     text,
  raised_at   timestamptz,
  changed_at  timestamptz,
  fetched_at  timestamptz not null,
  source_id   bigint not null references ingest.source(id),
  unique (area_id, changed_at, severity_level)
);
create index on core.flood_warning (fetched_at desc);
create index on core.flood_warning (source_id);

-- ───────────── Bathing ─────────────
create table core.bathing_assessment (
  site_id      bigint not null references core.site(id),
  year         smallint not null,
  classification text not null check (classification in ('excellent','good','sufficient','poor','not_classified')),
  rank         smallint,
  source_id    bigint not null references ingest.source(id),
  primary key (site_id, year, source_id)
);
create index on core.bathing_assessment (source_id);

create table core.bathing_forecast (
  site_id     bigint not null references core.site(id),
  issued_at   timestamptz not null,
  expires_at  timestamptz,
  risk_level  text not null check (risk_level in ('normal','increased','unknown')),
  reason      text,
  source_id   bigint not null references ingest.source(id),
  primary key (site_id, issued_at)
);
create index on core.bathing_forecast (source_id);

-- ───────────── WFD classification and reasons ─────────────
create table core.waterbody_classification (
  waterbody_id bigint not null references core.waterbody(id),
  cycle        smallint not null,
  year         smallint not null,
  element_code text not null references ref.classification_element(code),
  status       text not null,                           -- canonical: high|good|moderate|poor|bad|pass|fail|not_assessed|supports_good|does_not_support_good
  status_rank  smallint,                                -- 1 best .. 5 worst; null for pass/fail & not assessed
  status_native text,
  certainty    text,
  confidence   text,
  source_id    bigint not null references ingest.source(id),
  primary key (waterbody_id, cycle, year, element_code, source_id)
);
create index on core.waterbody_classification (element_code);
create index on core.waterbody_classification (source_id);
create index on core.waterbody_classification (year, element_code, status_rank);

create table core.waterbody_reason (          -- official "Reasons for Not Achieving Good" (RNAG) and "Reasons for Deterioration"
  id           bigint generated always as identity primary key,
  waterbody_id bigint not null references core.waterbody(id),
  cycle        smallint,
  element_code text references ref.classification_element(code),
  reason_type  text not null check (reason_type in ('RNAG','RFD')),
  sector_code  text references ref.pressure_sector(code),
  sector_native text,
  activity     text,
  pressure_type text,                                    -- point source | diffuse source | physical modification ...
  certainty    text,
  source_id    bigint not null references ingest.source(id),
  source_key   text,
  unique (source_id, source_key)
);
create index on core.waterbody_reason (waterbody_id);
create index on core.waterbody_reason (element_code);
create index on core.waterbody_reason (sector_code);
create index on core.waterbody_reason (source_id);

-- Modelled source apportionment (SEPARATE). evidence_class is 'modelled' and must be displayed as such.
create table core.waterbody_apportionment (
  waterbody_id bigint not null references core.waterbody(id),
  pollutant    text not null check (pollutant in ('phosphorus','nitrogen','sediment')),
  sector       text not null check (sector in ('agriculture','bank_erosion','urban_diffuse','sewage_works','storm_tanks','septic_tanks','combined_sewer_overflows','direct_deposition','other')),
  load_t_yr    numeric,
  share_pct    numeric check (share_pct between 0 and 100),
  model        text not null,
  model_version text not null default 'unknown',
  source_id    bigint not null references ingest.source(id),
  primary key (waterbody_id, pollutant, sector, model, model_version)
);
create index on core.waterbody_apportionment (source_id);
create index on core.waterbody_apportionment (pollutant, sector, share_pct desc);

-- ───────────── Citizen science ─────────────
create table core.survey (
  id            bigint generated always as identity primary key,
  source_id     bigint not null references ingest.source(id),
  source_key    text not null,
  kind          text not null check (kind in ('big_river_watch','riverfly_rmi','riverfly_urban','riverfly_extended_wq','riverfly_extended_silt_flow','morph','water_rangers','other')),
  site_id       bigint references core.site(id),
  surveyed_at   timestamptz,
  geom          geometry(Point,4326),
  waterbody_id  bigint references core.waterbody(id),
  river_id      bigint references core.river(id),
  summary_label text,                                     -- BRW 'health' answer / Riverfly breach type
  summary_score numeric,                                  -- Riverfly total
  breach        boolean,
  answers       jsonb not null default '{}',              -- the long tail of per-survey fields, lossless
  evidence_class core.evidence_class not null default 'citizen_science',
  unique (source_id, source_key)
);
create index on core.survey (kind, surveyed_at desc);
create index on core.survey (site_id);
create index on core.survey (waterbody_id);
create index on core.survey (river_id);
create index on core.survey using gist (geom);

-- Obstacles/barriers (EA River Obstacles) — ecological connectivity pressure
create table core.river_obstacle (
  id          bigint generated always as identity primary key,
  source_id   bigint not null references ingest.source(id),
  source_key  text not null,
  obstacle_type text,
  origin      text,
  fish_pass   text,
  height_m    numeric,
  geom        geometry(Point,4326) not null,
  waterbody_id bigint references core.waterbody(id),
  attrs       jsonb not null default '{}',
  unique (source_id, source_key)
);
create index on core.river_obstacle (waterbody_id);
create index on core.river_obstacle using gist (geom);
