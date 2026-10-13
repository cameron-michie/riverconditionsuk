-- 1. line geometry for waterbodies that only have a catchment polygon (Wales): the dominant OS river inside the polygon
with agg as (
  select waterbody_id, river_id, sum(length_m) len from geo.river_link where waterbody_id is not null and river_id is not null group by 1, 2),
best as (select distinct on (waterbody_id) waterbody_id, river_id from agg order by waterbody_id, len desc),
ln as (
  select b.waterbody_id, ST_Multi(ST_LineMerge(ST_Collect(l.geom))) geom, sum(l.length_m) / 1000 km
  from best b join geo.river_link l on l.waterbody_id = b.waterbody_id and l.river_id = b.river_id group by b.waterbody_id)
update geo.waterbody w set line_geom = ln.geom, length_km = coalesce(w.length_km, ln.km), attrs = w.attrs || '{"line_derived":"os_dominant_river"}'
from ln where ln.waterbody_id = w.id and w.line_geom is null and ST_GeometryType(ln.geom) in ('ST_MultiLineString');

-- 2. gauge flow now + percentile of record (NRFA gauged daily flow history of the same site)
drop table if exists core.gauge_flow_now;
create table core.gauge_flow_now as
with fl as (
  select s.id series_id, s.site_id, l.value, l.observed_at
  from live.series s join core.observation_latest l on l.series_id = s.id
  join ref.parameter p on p.id = s.parameter_id and p.code = 'river_flow'
  where s.source_id in (select id from ref.source where slug in ('ea_flood_monitoring','ea_hydrology')) and l.value is not null and l.observed_at > now() - interval '10 days'),
best as (select distinct on (site_id) * from fl order by site_id, observed_at desc),
nr as (select s.site_id, s.id series_id from live.series s join ref.source src on src.id = s.source_id and src.slug = 'nrfa')
select b.site_id, b.series_id, b.value, b.observed_at, nr.series_id nrfa_series_id,
       (select (count(*) filter (where o.value <= b.value))::real / nullif(count(*), 0) from live.observation o where o.series_id = nr.series_id and o.value is not null) pct_of_record,
       (select count(*) from live.observation o where o.series_id = nr.series_id and o.value is not null) n_record
from best b join nr on nr.site_id = b.site_id;
alter table core.gauge_flow_now add primary key (site_id);
create index on core.gauge_flow_now (series_id);
create index on core.gauge_flow_now (nrfa_series_id);
alter table core.gauge_flow_now enable row level security;
analyze core.gauge_flow_now;
select count(*) gauges_with_pct, round(avg(pct_of_record)::numeric, 2) mean_pct, max(observed_at) newest from core.gauge_flow_now;
select count(*) waterbodies_with_line, count(*) filter (where attrs ? 'line_derived') derived from geo.waterbody where line_geom is not null;
