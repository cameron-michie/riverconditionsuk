-- Earth-observation foundations: scenes, processing reaches, observations, calibration, events.
-- Satellite output is evidence_class 'modelled' until validated (see docs/MAP.md "Where the satellite work plugs in").

-- ---------------------------------------------------------------- scenes
create table core.scene (
  id           bigint generated always as identity primary key,
  stac_id      text not null,
  collection   text not null,                       -- sentinel-2-c1-l2a | sentinel-1-grd | landsat-c2-l2
  platform     text,
  tile         text,                                -- MGRS tile / relative orbit
  acquired_at  timestamptz not null,
  cloud_pct    real,
  bbox         geometry(Polygon,4326) not null,
  assets       jsonb not null default '{}',         -- band name -> href (COG)
  licence      text not null default 'Copernicus open licence',
  discovered_at timestamptz not null default now(),
  unique (collection, stac_id)
);
create index on core.scene (acquired_at desc);
create index on core.scene (collection, tile, acquired_at desc);
create index on core.scene using gist (bbox);

-- ---------------------------------------------------------------- reaches (processing units)
create table core.reach (
  id            bigint generated always as identity primary key,
  link_id       bigint not null references core.river_link(id) on delete cascade,
  seq           integer not null,
  waterbody_id  bigint references core.waterbody(id),
  form          text not null,
  length_m      real not null,
  width_m       real,                                -- estimated channel width (from water mask / Strahler prior)
  observable_s2 boolean not null default false,      -- true when width_m is enough for clean 10-20 m pixels
  geom          geometry(LineString,4326) not null,
  buffer_geom   geometry(Polygon,4326),              -- riparian buffer for canopy/land-use detectors
  last_scored_at timestamptz,
  unique (link_id, seq)
);
create index on core.reach (waterbody_id);
create index on core.reach (last_scored_at nulls first);
create index on core.reach using gist (geom);
create index on core.reach using gist (buffer_geom);

-- Split every link into ~500 m reaches. Idempotent: only links without reaches.
create or replace function core.build_reaches(p_target_m double precision default 500)
returns bigint language plpgsql as $$
declare n bigint;
begin
  insert into core.reach (link_id, seq, waterbody_id, form, length_m, geom)
  select l.id, g.i, l.waterbody_id, l.form,
         (l.length_m / greatest(1, ceil(l.length_m / p_target_m)))::real,
         st_linesubstring(l.geom, (g.i)::double precision / k.n, (g.i + 1)::double precision / k.n)
  from core.river_link l
  cross join lateral (select greatest(1, ceil(l.length_m / p_target_m))::int as n) k
  cross join lateral generate_series(0, k.n - 1) as g(i)
  where not exists (select 1 from core.reach r where r.link_id = l.id)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------- observations
create table core.eo_observation (
  id           bigint generated always as identity,
  reach_id     bigint not null,
  scene_id     bigint not null,
  observed_on  date not null,
  detector     text not null,                        -- chlorophyll | turbidity | flood | shoreline | canopy | ...
  algo_version text not null,
  metrics      jsonb not null,                       -- detector-specific (chl_median, ndci, valid_frac, canopy_loss_ha ...)
  valid_frac   real,                                 -- share of reach water/riparian pixels that passed QA
  confidence   real check (confidence between 0 and 1),
  evidence_class core.evidence_class not null default 'modelled',
  created_at   timestamptz not null default now(),
  primary key (id, observed_on),
  unique (reach_id, scene_id, detector, algo_version, observed_on)
) partition by range (observed_on);
create table core.eo_observation_default partition of core.eo_observation default;
create index on core.eo_observation (reach_id, detector, observed_on desc);

-- monthly partitions: created ahead by pg_cron below
create or replace function core.ensure_eo_partitions(p_months_ahead int default 3)
returns void language plpgsql as $$
declare m date; nm text;
begin
  for i in 0..p_months_ahead loop
    m := date_trunc('month', now() + make_interval(months => i))::date;
    nm := 'eo_observation_' || to_char(m, 'YYYYMM');
    if to_regclass('core.' || nm) is null then
      execute format('create table core.%I partition of core.eo_observation for values from (%L) to (%L)',
                     nm, m, (m + interval '1 month')::date);
    end if;
  end loop;
end $$;
select core.ensure_eo_partitions(3);

-- vector outputs (bloom / erosion / canopy-loss / flood polygons)
create table core.geo_observation (
  id          bigint generated always as identity,
  product     text not null,
  observed_on date not null,
  geom        geometry(Geometry,4326) not null,
  value       double precision,
  confidence  real,
  scene_id    bigint,
  run_id      bigint,
  evidence_class core.evidence_class not null default 'modelled',
  primary key (id, observed_on)
) partition by range (observed_on);
create table core.geo_observation_default partition of core.geo_observation default;
create index on core.geo_observation using gist (geom);
create index on core.geo_observation (product, observed_on desc);

-- ---------------------------------------------------------------- calibration (auditable accuracy)
create table core.eo_calibration (
  id            bigint generated always as identity primary key,
  detector      text not null,
  optical_class text not null default 'all',
  model         text not null,                       -- e.g. 'linear:ndci->chl'
  coefficients  jsonb not null,
  n_matchups    integer not null,
  r2            real,
  rmse          real,
  fitted_at     timestamptz not null default now(),
  is_current    boolean not null default true
);
create unique index on core.eo_calibration (detector, optical_class) where is_current;

create table core.eo_matchup (
  id          bigint generated always as identity primary key,
  reach_id    bigint not null,
  scene_id    bigint not null,
  site_id     bigint,
  detector    text not null,
  sat_value   double precision not null,
  insitu_value double precision not null,
  insitu_at   timestamptz not null,
  days_apart  real not null,
  distance_m  real not null,
  unique (scene_id, site_id, detector)
);

-- ---------------------------------------------------------------- derived events
create table core.eo_event (
  id          bigint generated always as identity primary key,
  reach_id    bigint not null,
  kind        text not null,                         -- bloom_onset | erosion_hotspot | canopy_loss | flood | turbid_plume
  started_on  date not null,
  ended_on    date,
  severity    smallint,
  confidence  real,
  basis       jsonb not null,                        -- observation ids + rule that fired
  review_status text not null default 'auto' check (review_status in ('auto','proposed','approved','rejected')),
  evidence_class core.evidence_class not null default 'modelled',
  created_at  timestamptz not null default now()
);
create index on core.eo_event (reach_id, kind, started_on desc);

-- ---------------------------------------------------------------- access: closed; exposed later via api RPCs
alter table core.scene           enable row level security;
alter table core.reach           enable row level security;
alter table core.eo_observation  enable row level security;
alter table core.geo_observation enable row level security;
alter table core.eo_calibration  enable row level security;
alter table core.eo_matchup      enable row level security;
alter table core.eo_event        enable row level security;

-- keep partitions ahead (pg_cron is enabled in migration 1)
select cron.schedule('eo-partitions', '0 3 1 * *', $$select core.ensure_eo_partitions(3)$$);

-- work queue for the always-on worker
select pgmq.create('eo_jobs');
