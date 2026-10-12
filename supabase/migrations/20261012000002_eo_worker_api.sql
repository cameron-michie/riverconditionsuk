-- Worker registration, observability prior, and the first read RPC for satellite chlorophyll.

insert into ops.etl_job (name, command, interval_minutes, enabled) values
  ('eo_worker', 'always-on container (worker/); rows here are its per-scene run log', 1440, false)
on conflict (name) do nothing;   -- disabled: the scheduler must not try to launch it, the container runs itself

-- Width prior until the worker measures real width from water masks.
-- Sentinel-2 needs roughly >=40 m of channel for clean 10-20 m pixels after edge erosion.
create or replace function core.mark_observable()
returns bigint language plpgsql as $$
declare n bigint;
begin
  update core.reach r set
    width_m = case when l.form in ('lake','tidalRiver') then 100
                   when l.strahler >= 7 then 80
                   when l.strahler = 6 then 50
                   when l.strahler = 5 then 25
                   else 10 end,
    observable_s2 = (l.form in ('lake','tidalRiver') or coalesce(l.strahler, 0) >= 6)
  from core.river_link l
  where l.id = r.link_id and r.width_m is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Weekly satellite chlorophyll for a river, aggregated over its observable reaches.
create or replace function api.eo_chlorophyll(p_slug text, p_weeks int default 52)
returns jsonb language sql stable security definer set search_path = '' as $$
with r as (select id from core.river where slug = p_slug),
obs as (
  select date_trunc('week', o.observed_on)::date wk,
         (o.metrics->>'chl_median')::float chl, (o.metrics->>'chl_p90')::float p90,
         (o.metrics->>'bloom_frac')::float bloom, o.confidence
  from core.eo_observation o
  join core.reach re on re.id = o.reach_id
  join core.river_link l on l.id = re.link_id
  join r on r.id = l.river_id
  where o.detector = 'chlorophyll' and o.observed_on >= now() - make_interval(weeks => p_weeks)
)
select jsonb_build_object(
  'evidence_class', 'modelled',
  'method', 'Sentinel-2 NDCI, per-reach median over clean water pixels',
  'weeks', coalesce(jsonb_agg(jsonb_build_object(
      'week', wk, 'chl_median', round(m::numeric, 2), 'chl_p90', round(p::numeric, 2),
      'bloom_frac', round(b::numeric, 3), 'n_obs', n) order by wk), '[]'::jsonb))
from (select wk, percentile_cont(0.5) within group (order by chl) m, max(p90) p,
             avg(bloom) b, count(*) n
      from obs group by wk) x;
$$;
