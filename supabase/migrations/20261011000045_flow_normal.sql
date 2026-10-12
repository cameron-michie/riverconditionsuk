-- "Normal for this time of year" per gauge, from daily-mean flow history (NRFA to 2025, EA Hydrology from 2003).
-- Quantiles 0,5,...,100 % of daily flow within +-15 days of each 10th day of the year, over all years on record.
create table if not exists core.flow_normal (
  site_id bigint not null references core.site(id) on delete cascade,
  doy smallint not null,
  q double precision[] not null,
  n int not null,
  years int not null,
  primary key (site_id, doy)
);
alter table core.flow_normal enable row level security;

create or replace function core.refresh_flow_normal() returns void language plpgsql as $$
begin
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

-- percentile (0..100) of a flow among the gauge's seasonal normal
create or replace function core.seasonal_pct(p_site bigint, p_flow double precision, p_at timestamptz default now()) returns real language plpgsql stable as $$
declare qs double precision[]; i int; lo double precision; hi double precision; d int := extract(doy from p_at)::int; step int;
begin
  step := 1 + 10 * round((d - 1) / 10.0)::int; if step > 366 then step := 361; end if;
  select q into qs from core.flow_normal where site_id = p_site and doy = step; if qs is null then return null; end if;
  if p_flow <= qs[1] then return 0; end if; if p_flow >= qs[21] then return 100; end if;
  for i in 1..20 loop
    if p_flow <= qs[i + 1] then lo := qs[i]; hi := qs[i + 1]; return ((i - 1) * 5 + case when hi > lo then 5 * (p_flow - lo) / (hi - lo) else 2.5 end)::real; end if;
  end loop;
  return null;
end $$;

insert into ops.etl_job (name, command, interval_minutes) values
 ('flow_normal', 'python3 -c "from db import connect; c = connect(); c.cursor().execute(''select core.refresh_flow_normal()''); c.commit()"', 10080)
on conflict (name) do nothing;
update ops.etl_job set command = 'python3 -W ignore refresh_flow.py && python3 -W ignore refresh_live.py' where name = 'live';
