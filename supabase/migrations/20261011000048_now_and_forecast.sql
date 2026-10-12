-- "Now + 5 days" model. Hot tables hold the present and the forecast; anything older is archived to Storage (ops.archive_object).
--   core.forecast        gauge-level forecasts, same series_id as the observed series
--   core.waterbody_flow  modelled flow per waterbody, hindcast (-48 h) through forecast (+5 d), evidence class 'modelled'
--   wx.*                 weather: radar / forecast image frames, isobars, catchment-average rain

create schema if not exists wx;

-- gauge_flow_now was only created by scripts/load/derive_extras.sql, so a db reset left a broken schema. Declare it here; derive_extras still refills it.
create table if not exists core.gauge_flow_now (
  site_id bigint primary key references core.site(id),
  series_id bigint,
  value double precision,
  observed_at timestamptz,
  nrfa_series_id bigint,
  pct_of_record real,
  n_record bigint
);
create index if not exists gauge_flow_now_series on core.gauge_flow_now (series_id);
create index if not exists gauge_flow_now_nrfa on core.gauge_flow_now (nrfa_series_id);

-- Forecast of an observed series. One row per (series, model run, valid time). Daily partitions on valid_at.
create table if not exists core.forecast (
  series_id bigint not null,
  issued_at timestamptz not null,
  valid_at  timestamptz not null,
  value     double precision not null,
  p10       double precision,
  p90       double precision,
  primary key (series_id, issued_at, valid_at)
) partition by range (valid_at);
create table if not exists core.forecast_default partition of core.forecast default;
create index if not exists forecast_valid on core.forecast using brin (valid_at);

create table if not exists core.waterbody_flow (
  waterbody_id bigint not null references core.waterbody(id),
  issued_at    timestamptz not null,
  valid_at     timestamptz not null,
  flow_m3s     double precision,
  flow_pct     real,                       -- seasonal percentile, same scale as core.flow_state_rule
  method       text not null,              -- 'measured' | 'transfer' | 'rain_routed'
  confidence   text,
  basis        jsonb not null default '{}',
  primary key (waterbody_id, issued_at, valid_at)
) partition by range (valid_at);
create table if not exists core.waterbody_flow_default partition of core.waterbody_flow default;
create index if not exists waterbody_flow_valid on core.waterbody_flow using brin (valid_at);

-- Weather. A frame is one georeferenced PNG in the public 'weather' bucket.
create table if not exists wx.frame (
  id           bigint generated always as identity primary key,
  product      text not null,              -- 'radar_rain' | 'ifs_rain' | ...
  issued_at    timestamptz not null,       -- model run / radar scan time
  valid_at     timestamptz not null,
  storage_path text not null,
  bbox         double precision[] not null check (cardinality(bbox) = 4),   -- minx, miny, maxx, maxy in EPSG:4326
  legend       jsonb not null default '{}',
  unique (product, issued_at, valid_at)
);
create index if not exists frame_product_valid on wx.frame (product, valid_at desc);

create table if not exists wx.contour (
  id        bigint generated always as identity primary key,
  product   text not null,                 -- 'ifs_mslp'
  issued_at timestamptz not null,
  valid_at  timestamptz not null,
  level     real not null,                 -- hPa
  geom      geometry(MultiLineString, 4326) not null
);
create index if not exists contour_valid on wx.contour (product, valid_at);
create index if not exists contour_geom on wx.contour using gist (geom);

create table if not exists wx.catchment_rain (
  waterbody_id bigint not null references core.waterbody(id),
  source       text not null,              -- 'radar' | 'ifs'
  issued_at    timestamptz not null,
  valid_at     timestamptz not null,
  mm           real not null,              -- accumulated over the step ending at valid_at
  step_min     smallint not null,
  primary key (waterbody_id, source, issued_at, valid_at)
);
create index if not exists catchment_rain_valid on wx.catchment_rain using brin (valid_at);

-- Cold archive ledger. A hot partition is dropped only after its archive row exists with a matching row count.
create table if not exists ops.archive_object (
  id           bigint generated always as identity primary key,
  dataset      text not null,              -- 'observation' | 'forecast' | 'raw:<source>' ...
  period_start timestamptz not null,
  period_end   timestamptz not null,
  bucket       text not null default 'archive',
  path         text not null,
  rows         bigint not null,
  bytes        bigint,
  sha256       text,
  archived_at  timestamptz not null default now(),
  dropped_at   timestamptz,
  unique (dataset, period_start, period_end)
);

-- Scheduler additions: which source a job refreshes, and how stale is too stale.
alter table ops.etl_job add column if not exists source_slug text;
alter table ops.etl_job add column if not exists timeout_s int not null default 900;
alter table ops.etl_job add column if not exists max_lag_minutes int;

-- Daily partitions for the forecast tables: p_back days behind now through p_ahead days ahead. Safe to rerun.
create or replace function ops.roll_forecast_partitions(p_back int default 3, p_ahead int default 8) returns int language plpgsql as $$
declare d date; n int := 0; t text;
begin
  for d in select generate_series((now() - make_interval(days => p_back))::date, (now() + make_interval(days => p_ahead))::date, interval '1 day')::date loop
    foreach t in array array['forecast', 'waterbody_flow'] loop
      if to_regclass(format('core.%I_%s', t, to_char(d, 'YYYYMMDD'))) is null then
        execute format('create table core.%I_%s partition of core.%I for values from (%L) to (%L)', t, to_char(d, 'YYYYMMDD'), t, d, d + 1);
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end $$;
select ops.roll_forecast_partitions();

do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname in ('wx', 'ops') or (schemaname = 'core' and (tablename like 'forecast%' or tablename like 'waterbody_flow%' or tablename = 'gauge_flow_now')) loop
    execute format('alter table %I.%I enable row level security', t.schemaname, t.tablename);
  end loop;
end $$;
revoke all on all tables in schema wx from anon, authenticated;
revoke usage on schema wx from anon, authenticated;
