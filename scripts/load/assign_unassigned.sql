-- second-pass waterbody assignment for anything still unassigned (e.g. after loading Welsh polygons)
analyze core.waterbody;
update core.river_link l set waterbody_id = w.id
from (select distinct on (l2.id) l2.id lid, w2.id
      from core.river_link l2 join core.waterbody w2 on w2.country = 'WLS' and w2.catchment_geom is not null and ST_Intersects(w2.catchment_geom, ST_LineInterpolatePoint(l2.geom, 0.5))
      where l2.waterbody_id is null order by l2.id, w2.area_km2) w where w.lid = l.id;
update core.site s set waterbody_id = l.waterbody_id from core.river_link l where s.river_link_id = l.id and s.waterbody_id is null and l.waterbody_id is not null;
update core.site s set waterbody_id = w.id
from (select distinct on (s2.id) s2.id sid, w2.id from core.site s2 join core.waterbody w2 on w2.country = 'WLS' and ST_Intersects(w2.catchment_geom, s2.geom)
      where s2.waterbody_id is null and s2.kind not in ('rain_gauge','groundwater_station','weather_station') and s2.merged_into is null order by s2.id, w2.area_km2) w where w.sid = s.id;
update core.survey s set waterbody_id = w.id from (select distinct on (s2.id) s2.id sid, w2.id from core.survey s2 join core.waterbody w2 on w2.country='WLS' and ST_Intersects(w2.catchment_geom, s2.geom) where s2.waterbody_id is null order by s2.id, w2.area_km2) w where w.sid = s.id;
select (select count(*) from core.river_link where waterbody_id is not null) links_with_wb, (select count(*) from core.river_link) links;
