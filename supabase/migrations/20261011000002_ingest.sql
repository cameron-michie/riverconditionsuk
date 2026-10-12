-- Provenance: every fact in core points to a source, and every source to a licence.

create table ingest.licence (
  id                    bigint generated always as identity primary key,
  slug                  text not null unique,
  name                  text not null,
  url                   text,
  allows_redistribution boolean,        -- null = unknown / needs confirmation
  allows_commercial     boolean,
  requires_attribution  boolean not null default true,
  attribution_text      text,
  notes                 text
);

create table ingest.source (
  id             bigint generated always as identity primary key,
  slug           text not null unique,                       -- e.g. 'ea_flood_monitoring'
  name           text not null,
  publisher      text not null,
  country        text,                                       -- GB | ENG | WLS | SCT | NIR
  kind           text not null check (kind in ('rest_api','arcgis_feature_service','ogc_features','wfs','bulk_csv','bulk_file','scrape','pdf','manual','stac')),
  base_url       text,
  licence_id     bigint references ingest.licence(id),
  evidence_class core.evidence_class not null,
  cadence        text,                                       -- 'PT15M', 'P1D', 'P1Y' (ISO 8601) — how often it changes upstream
  expected_lag   text,                                       -- publication lag, e.g. 'P2D'
  status         text not null default 'active' check (status in ('active','blocked','planned','retired','gap')),
  status_note    text,                                       -- why blocked / what is missing
  contract       jsonb not null default '{}',                -- expected fields/types per adapter: schema-drift detector input
  notes          text
);
create index on ingest.source (licence_id);

create table ingest.run (
  id            bigint generated always as identity primary key,
  source_id     bigint not null references ingest.source(id),
  adapter       text not null,                               -- script / worker name + version
  params        jsonb not null default '{}',
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  status        text not null default 'running' check (status in ('running','ok','partial','failed')),
  rows_read     bigint,
  rows_written  bigint,
  rows_rejected bigint,
  error         text
);
create index on ingest.run (source_id, started_at desc);

create table ingest.raw_object (
  id          bigint generated always as identity primary key,
  source_id   bigint not null references ingest.source(id),
  run_id      bigint references ingest.run(id),
  path        text not null,                                 -- location in object storage / local data/raw
  url         text,
  sha256      text not null,
  bytes       bigint not null,
  fetched_at  timestamptz not null,
  note        text,
  unique (path, sha256)
);
create index on ingest.raw_object (source_id, fetched_at desc);
create index on ingest.raw_object (run_id);

-- Rows we refused, with the reason. Rejection is data, not silence.
create table ingest.reject (
  id         bigint generated always as identity primary key,
  source_id  bigint not null references ingest.source(id),
  run_id     bigint references ingest.run(id),
  reason     text not null,
  payload    jsonb,
  created_at timestamptz not null default now()
);
create index on ingest.reject (source_id, created_at desc);
create index on ingest.reject (run_id);
