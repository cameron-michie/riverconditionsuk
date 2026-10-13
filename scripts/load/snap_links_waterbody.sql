-- 1. waterbody for every river link (link's interior point inside a waterbody catchment; smallest catchment wins)
update geo.river_link l set waterbody_id = w.id
from (
  select distinct on (l2.id) l2.id lid, w2.id
  from geo.river_link l2
  join geo.waterbody w2 on w2.catchment_geom is not null and ST_Intersects(w2.catchment_geom, ST_LineInterpolatePoint(l2.geom, 0.5))
  order by l2.id, w2.area_km2 asc nulls last
) w where w.lid = l.id;

