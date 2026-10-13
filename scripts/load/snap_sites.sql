-- 2. nearest link (KNN on BNG GiST), accepted only inside a per-kind tolerance
with k as (
  select s.id sid, s.kind, n.id lid, n.river_id, n.waterbody_id, n.length_m, n.dist_to_mouth_m,
         ST_Distance(s.geom_bng, n.geom_bng) d,
         ST_LineLocatePoint(n.geom_bng, s.geom_bng) frac
  from geo.site s
  cross join lateral (
    select id, river_id, waterbody_id, length_m, dist_to_mouth_m, geom_bng from geo.river_link
    order by geom_bng <-> s.geom_bng limit 1) n
  where s.geom_bng is not null
    and s.kind in ('river_gauge','wq_sampling_point','sonde','storm_overflow','sewage_works','consented_discharge','bathing_water','survey_site')
)
update geo.site s set
  snap_distance_m = k.d,
  river_link_id   = case when k.d <= case k.kind when 'river_gauge' then 300 when 'wq_sampling_point' then 300 when 'sonde' then 300
                                 when 'bathing_water' then 1000 else 500 end then k.lid end,
  river_id        = case when k.d <= case k.kind when 'river_gauge' then 300 when 'wq_sampling_point' then 300 when 'sonde' then 300
                                 when 'bathing_water' then 1000 else 500 end then k.river_id end,
  dist_to_mouth_m = case when k.d <= 500 and k.dist_to_mouth_m is not null then greatest(0, k.dist_to_mouth_m - k.frac * coalesce(k.length_m, 0)) end
from k where k.sid = s.id;

-- 3. waterbody for every site: via its link when snapped, else by point-in-catchment
update geo.site s set waterbody_id = l.waterbody_id from geo.river_link l where s.river_link_id = l.id and l.waterbody_id is not null;
update geo.site s set waterbody_id = w.id
from (
  select distinct on (s2.id) s2.id sid, w2.id
  from geo.site s2 join geo.waterbody w2 on w2.catchment_geom is not null and ST_Intersects(w2.catchment_geom, s2.geom)
  where s2.waterbody_id is null and s2.kind not in ('rain_gauge','groundwater_station','weather_station') and s2.merged_into is null
  order by s2.id, w2.area_km2 asc nulls last
) w where w.sid = s.id;

analyze geo.site; analyze geo.river_link;
select kind, count(*) n, count(river_link_id) snapped, count(waterbody_id) in_wb, round(avg(snap_distance_m)::numeric) avg_snap_m
from geo.site where merged_into is null group by 1 order by 2 desc;
