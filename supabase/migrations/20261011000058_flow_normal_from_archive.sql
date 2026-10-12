-- Daily flow history now lives in the cold archive, so the normals are rebuilt by scripts/etl/flow_normal_refresh.py (Parquet + hot rows).
-- The SQL rebuild would silently rebuild from the few days left in Postgres: refuse unless the full history is present.
create or replace function core.refresh_flow_normal() returns void language plpgsql as $$
declare hist bigint;
begin
  select count(*) into hist from core.observation o join core.series s on s.id = o.series_id
   where s.interval_s = 86400 and o.observed_at < now() - interval '1 year';
  if hist < 1000000 then
    raise exception 'daily flow history is archived (% rows older than a year in Postgres): run scripts/etl/flow_normal_refresh.py instead', hist;
  end if;
  truncate core.flow_normal;
  insert into core.flow_normal (site_id, doy, q, n, years)
  with hist as (
    select distinct on (s.site_id, o.observed_at::date) s.site_id, o.observed_at::date d, o.value
    from core.series s join ref.parameter p on p.id = s.parameter_id and p.code = 'river_flow'
    join ingest.source src on src.id = s.source_id and src.slug in ('nrfa', 'ea_hydrology')
    join core.observation o on o.series_id = s.id
    where s.aggregation = 'mean' and s.interval_s = 86400 and o.value >= 0
    order by s.site_id, o.observed_at::date, (src.slug = 'nrfa') desc),
  h as (select site_id, value, extract(doy from d)::int doy, extract(year from d)::int yr from hist),
  steps as (select generate_series(1, 366, 10) step)
  select h.site_id, st.step, percentile_cont(array(select i / 20.0 from generate_series(0, 20) i)) within group (order by h.value), count(*), count(distinct h.yr)
  from h join steps st on least(abs(h.doy - st.step), 366 - abs(h.doy - st.step)) <= 15
  group by h.site_id, st.step having count(distinct h.yr) >= 3;
end $$;
update ops.etl_job set command = '../../.venv/bin/python -W ignore ../etl/flow_normal_refresh.py' where name = 'flow_normal';
insert into ops.etl_job (name, command, interval_minutes, timeout_s, max_lag_minutes) values
  ('archive', '../../.venv/bin/python -W ignore ../etl/archive.py', 1440, 3600, 2880)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
