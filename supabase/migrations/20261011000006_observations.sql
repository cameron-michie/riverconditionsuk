-- Measurements. Four layers: series (what is measured, where, how) -> sample (a lab visit) -> observation (value) -> rollups.

create table core.series (
  id                bigint generated always as identity primary key,
  site_id           bigint not null references core.site(id),
  parameter_id      bigint not null references ref.parameter(id),
  source_id         bigint not null references ingest.source(id),
  source_series_key text not null,             -- EA measure id / SEPA ts_id / NRFA station+data-type / 'wims:<point>:<determinand>'
  aggregation       text not null check (aggregation in ('instant','mean','min','max','sum','median','count','latest')),
  interval_s        integer,                   -- 900 = 15 min, 86400 = daily, null = irregular (lab samples)
  unit_id           text not null references ref.unit(id),   -- canonical unit of stored values
  native_unit       text,
  qualifier         text,                      -- 'downstage' | 'stage' | 'tipping_bucket' | 'qualified'
  datum             text,                      -- 'mAOD' | 'mASD' : levels are NOT comparable across datums
  matrix            text not null default 'river_water',
  fraction          text,
  method            text,
  evidence_class    core.evidence_class not null,
  is_preferred      boolean not null default false,   -- display rule: one preferred series per site+parameter
  status            text not null default 'active' check (status in ('active','stale','retired')),
  first_at          timestamptz,
  last_at           timestamptz,
  attrs             jsonb not null default '{}',
  unique (source_id, source_series_key)
);
create index on core.series (site_id, parameter_id);
create index on core.series (parameter_id);
create index on core.series (unit_id);
create index on core.series (site_id) where is_preferred;

-- A lab/field visit: groups the observations taken together and carries purpose + compliance flags.
create table core.sample (
  id                 bigint generated always as identity primary key,
  site_id            bigint not null references core.site(id),
  source_id          bigint not null references ingest.source(id),
  source_sample_key  text not null,
  sampled_at         timestamptz not null,
  material           text,
  purpose            text,
  is_compliance      boolean,
  unique (source_id, source_sample_key)
);
create index on core.sample (site_id, sampled_at desc);

-- The big table. Partitioned by time (yearly pre-2020, monthly after). No TimescaleDB on Supabase: native partitions + BRIN.
create table core.observation (
  series_id        bigint not null,
  observed_at      timestamptz not null,       -- instant, or START of the aggregation period when interval_s is set. Always UTC.
  value            double precision,           -- canonical unit; null when only censored/missing
  censor           text check (censor in ('<','>')),   -- '<0.105' => censor '<', detection_limit 0.105, value null
  detection_limit  double precision,
  value_raw        text,                        -- original string kept ONLY when we changed it (censored, sentinel, converted)
  quality          text not null default 'unchecked' check (quality in ('good','estimated','suspect','provisional','unchecked','invalid','missing')),
  completeness     real check (completeness between 0 and 1),
  sample_id        bigint,
  run_id           bigint,
  primary key (series_id, observed_at)
) partition by range (observed_at);

do $$
declare y int; m int; s date;
begin
  for y in 1990..2019 loop
    execute format('create table core.observation_y%s partition of core.observation for values from (%L) to (%L)', y, make_date(y,1,1), make_date(y+1,1,1));
  end loop;
  for y in 2020..2028 loop
    for m in 1..12 loop
      s := make_date(y,m,1);
      execute format('create table core.observation_%s_%s partition of core.observation for values from (%L) to (%L)', y, lpad(m::text,2,'0'), s, (s + interval '1 month')::date);
    end loop;
  end loop;
end $$;
create table core.observation_default partition of core.observation default;

create index observation_observed_brin on core.observation using brin (observed_at);
create index observation_sample_idx on core.observation (sample_id) where sample_id is not null;
create index observation_run_idx on core.observation (run_id);

-- FKs on a partitioned child side are supported; keep them off the hot path and verify with a DQ check instead.
-- (series_id -> core.series is enforced by the loader and by ops.dq_orphan_observations.)

-- Latest value per series: what the map reads. Maintained by upsert in the adapters (or a trigger-free job).
create table core.observation_latest (
  series_id   bigint primary key references core.series(id),
  observed_at timestamptz not null,
  value       double precision,
  censor      text,
  quality     text,
  updated_at  timestamptz not null default now()
);
create index on core.observation_latest (observed_at desc);

-- Daily rollup for trends and sparklines; recomputed incrementally.
create table core.observation_daily (
  series_id bigint not null references core.series(id),
  day       date not null,
  n         integer not null,
  min       double precision,
  mean      double precision,
  max       double precision,
  sum       double precision,
  n_censored integer not null default 0,
  primary key (series_id, day)
);
