-- Derived geometry: waterbody lines for catchment-only waterbodies.
-- 1. line geometry for waterbodies that only have a catchment polygon (Wales): the dominant OS river inside the polygon
with agg as (
  select waterbody_id, river_id, sum(length_m) len from geo.river_link where waterbody_id is not null and river_id is not null group by 1, 2),
best as (select distinct on (waterbody_id) waterbody_id, river_id from agg order by waterbody_id, len desc),
ln as (
  select b.waterbody_id, ST_Multi(ST_LineMerge(ST_Collect(l.geom))) geom, sum(l.length_m) / 1000 km
  from best b join geo.river_link l on l.waterbody_id = b.waterbody_id and l.river_id = b.river_id group by b.waterbody_id)
update geo.waterbody w set line_geom = ln.geom, length_km = coalesce(w.length_km, ln.km), ids = w.ids || '{"line_derived":"os_dominant_river"}'
from ln where ln.waterbody_id = w.id and w.line_geom is null and ST_GeometryType(ln.geom) in ('ST_MultiLineString');

select count(*) waterbodies_with_line, count(*) filter (where ids ? 'line_derived') derived from geo.waterbody where line_geom is not null;
