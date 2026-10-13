-- Ready-made serving tables for satellite results. The worker refreshes these after every scene
-- (core.refresh_eo_serving); the frontend only ever SELECTs from the api.* views over them.

-- Provisional chlorophyll-a bands (ug/L). Uncalibrated until core.eo_calibration holds a fitted model.
create or replace function core.eo_chl_band(chl double precision)
returns text language sql immutable as $$
  select case when chl is null then 'unknown'
              when chl < 10 then 'low'
              when chl < 25 then 'moderate'
              when chl < 50 then 'high'
              else 'very_high' end $$;

-- ---------------------------------------------------------------- latest reading per reach (map layer, reach detail)
create table core.eo_reach_latest (
  reach_id     bigint primary key references core.reach(id) on delete cascade,
  detector     text not null default 'chlorophyll',
  observed_on  date not null,
  scene_id     bigint not null,
  chl_median   real,
  chl_p90      real,
  bloom_frac   real,
  valid_frac   real,
  confidence   real,
  band         text not null,
  n_obs_28d    integer not null default 1,
  chl_median_28d real,                               -- 28-day mean of reach medians, smooths cloud gaps
  updated_at   timestamptz not null default now()
);
create index on core.eo_reach_latest (observed_on desc);

-- ---------------------------------------------------------------- weekly rollups (river dossier, waterbody tiles)
create table core.eo_waterbody_week (
  waterbody_id bigint not null references core.waterbody(id) on delete cascade,
  week         date not null,
  detector     text not null default 'chlorophyll',
  chl_median   real,
  chl_p90      real,
  bloom_frac   real,
  reaches_observed integer not null,
  reaches_observable integer not null,
  coverage     real not null,                        -- observed / observable
  n_obs        integer not null,
  band         text not null,
  updated_at   timestamptz not null default now(),
  primary key (waterbody_id, week, detector)
);

create table core.eo_river_week (
  river_id     bigint not null references core.river(id) on delete cascade,
  week         date not null,
  detector     text not null default 'chlorophyll',
  chl_median   real,
  chl_p90      real,
  bloom_frac   real,
  reaches_observed integer not null,
  reaches_observable integer not null,
  coverage     real not null,
  n_obs        integer not null,
  band         text not null,
  updated_at   timestamptz not null default now(),
  primary key (river_id, week, detector)
);

alter table core.eo_reach_latest   enable row level security;
alter table core.eo_waterbody_week enable row level security;
alter table core.eo_river_week     enable row level security;

-- ---------------------------------------------------------------- incremental refresh, one scene at a time
create or replace function core.refresh_eo_serving(p_scene_id bigint)
returns void language plpgsql as $$
declare d date;
begin
  select acquired_at::date into d from core.scene where id = p_scene_id;
  if d is null then return; end if;

  -- 1. latest per reach (only moves forward in time)
  insert into core.eo_reach_latest (reach_id, observed_on, scene_id, chl_median, chl_p90, bloom_frac, valid_frac,
                                    confidence, band, n_obs_28d, chl_median_28d)
  select o.reach_id, o.observed_on, o.scene_id,
         (o.metrics->>'chl_median')::real, (o.metrics->>'chl_p90')::real, (o.metrics->>'bloom_frac')::real,
         o.valid_frac, o.confidence, core.eo_chl_band((o.metrics->>'chl_median')::float),
         w.n, w.m
  from core.eo_observation o
  cross join lateral (
    select count(*)::int n, avg((x.metrics->>'chl_median')::float)::real m
    from core.eo_observation x
    where x.reach_id = o.reach_id and x.detector = 'chlorophyll' and x.observed_on > o.observed_on - 28
      and x.observed_on <= o.observed_on) w
  where o.scene_id = p_scene_id and o.detector = 'chlorophyll'
  on conflict (reach_id) do update set
    observed_on = excluded.observed_on, scene_id = excluded.scene_id, chl_median = excluded.chl_median,
    chl_p90 = excluded.chl_p90, bloom_frac = excluded.bloom_frac, valid_frac = excluded.valid_frac,
    confidence = excluded.confidence, band = excluded.band, n_obs_28d = excluded.n_obs_28d,
    chl_median_28d = excluded.chl_median_28d, updated_at = now()
  where core.eo_reach_latest.observed_on <= excluded.observed_on;

  -- 2. weekly rollups for the waterbodies / rivers this scene touched (recomputed from observations = exact)
  insert into core.eo_waterbody_week (waterbody_id, week, chl_median, chl_p90, bloom_frac,
                                      reaches_observed, reaches_observable, coverage, n_obs, band)
  select a.waterbody_id, a.wk, a.med, a.p90, a.bloom, a.obs, greatest(t.n, a.obs),
         a.obs::real / greatest(t.n, a.obs, 1), a.n, core.eo_chl_band(a.med)
  from (
    select re.waterbody_id, date_trunc('week', o.observed_on)::date wk,
           percentile_cont(0.5) within group (order by (o.metrics->>'chl_median')::float)::real med,
           max((o.metrics->>'chl_p90')::float)::real p90,
           avg((o.metrics->>'bloom_frac')::float)::real bloom,
           count(distinct o.reach_id)::int obs, count(*)::int n
    from core.eo_observation o join core.reach re on re.id = o.reach_id
    where o.detector = 'chlorophyll' and re.waterbody_id is not null
      and re.waterbody_id in (select r2.waterbody_id from core.eo_observation o2 join core.reach r2 on r2.id = o2.reach_id
                              where o2.scene_id = p_scene_id)
      and date_trunc('week', o.observed_on) = date_trunc('week', d::timestamp)
    group by 1, 2) a
  join lateral (select count(*)::int n from core.reach r3 where r3.waterbody_id = a.waterbody_id and r3.observable_s2) t on true
  on conflict (waterbody_id, week, detector) do update set
    chl_median = excluded.chl_median, chl_p90 = excluded.chl_p90, bloom_frac = excluded.bloom_frac,
    reaches_observed = excluded.reaches_observed, reaches_observable = excluded.reaches_observable,
    coverage = excluded.coverage, n_obs = excluded.n_obs, band = excluded.band, updated_at = now();

  insert into core.eo_river_week (river_id, week, chl_median, chl_p90, bloom_frac,
                                  reaches_observed, reaches_observable, coverage, n_obs, band)
  select a.river_id, a.wk, a.med, a.p90, a.bloom, a.obs, greatest(t.n, a.obs),
         a.obs::real / greatest(t.n, a.obs, 1), a.n, core.eo_chl_band(a.med)
  from (
    select l.river_id, date_trunc('week', o.observed_on)::date wk,
           percentile_cont(0.5) within group (order by (o.metrics->>'chl_median')::float)::real med,
           max((o.metrics->>'chl_p90')::float)::real p90,
           avg((o.metrics->>'bloom_frac')::float)::real bloom,
           count(distinct o.reach_id)::int obs, count(*)::int n
    from core.eo_observation o
    join core.reach re on re.id = o.reach_id join core.river_link l on l.id = re.link_id
    where o.detector = 'chlorophyll' and l.river_id is not null
      and l.river_id in (select l2.river_id from core.eo_observation o2 join core.reach r2 on r2.id = o2.reach_id
                         join core.river_link l2 on l2.id = r2.link_id where o2.scene_id = p_scene_id)
      and date_trunc('week', o.observed_on) = date_trunc('week', d::timestamp)
    group by 1, 2) a
  join lateral (select count(*)::int n from core.reach r3 join core.river_link l3 on l3.id = r3.link_id
                where l3.river_id = a.river_id and r3.observable_s2) t on true
  on conflict (river_id, week, detector) do update set
    chl_median = excluded.chl_median, chl_p90 = excluded.chl_p90, bloom_frac = excluded.bloom_frac,
    reaches_observed = excluded.reaches_observed, reaches_observable = excluded.reaches_observable,
    coverage = excluded.coverage, n_obs = excluded.n_obs, band = excluded.band, updated_at = now();
end $$;

-- ---------------------------------------------------------------- what the frontend reads: plain views, no aggregation
create or replace view api.eo_reach_latest as
  select reach_id, observed_on, chl_median, chl_p90, bloom_frac, valid_frac, confidence, band, n_obs_28d, chl_median_28d
  from core.eo_reach_latest;

create or replace view api.eo_waterbody_week as
  select waterbody_id, week, chl_median, chl_p90, bloom_frac, reaches_observed, reaches_observable, coverage, n_obs, band
  from core.eo_waterbody_week;

create or replace view api.eo_river_week as
  select w.river_id, r.slug as river_slug, w.week, w.chl_median, w.chl_p90, w.bloom_frac,
         w.reaches_observed, w.reaches_observable, w.coverage, w.n_obs, w.band
  from core.eo_river_week w join core.river r on r.id = w.river_id;

-- the earlier on-the-fly RPC now just reads the serving table
create or replace function api.eo_chlorophyll(p_slug text, p_weeks int default 52)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'evidence_class', 'modelled',
    'method', 'Sentinel-2 NDCI, uncalibrated; per-reach medians rolled up weekly',
    'weeks', coalesce(jsonb_agg(jsonb_build_object(
        'week', w.week, 'chl_median', w.chl_median, 'chl_p90', w.chl_p90, 'bloom_frac', w.bloom_frac,
        'band', w.band, 'coverage', w.coverage, 'reaches_observed', w.reaches_observed,
        'reaches_observable', w.reaches_observable) order by w.week), '[]'::jsonb))
  from core.eo_river_week w join core.river r on r.id = w.river_id
  where r.slug = p_slug and w.week >= (now() - make_interval(weeks => p_weeks))::date;
$$;

-- one-off backfill of everything already observed, and a nightly safety net via pg_cron
create or replace function core.rebuild_eo_serving(p_days int default null)
returns bigint language plpgsql as $$
declare s record; n bigint := 0;
begin
  for s in select distinct scene_id from core.eo_observation
           where p_days is null or observed_on >= current_date - p_days order by 1 loop
    perform core.refresh_eo_serving(s.scene_id); n := n + 1;
  end loop;
  return n;
end $$;
select core.rebuild_eo_serving();                                   -- full backfill once
select cron.schedule('eo-serving-rebuild', '30 3 * * *', $$select core.rebuild_eo_serving(14)$$);
