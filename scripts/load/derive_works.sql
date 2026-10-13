-- Which sites are sewage works on the map, and which monitoring point measures each. Run after load_sites.py, load_series.py wq and load_effluent.py.
-- A works is either a water-company treatment works permit (attrs.works = 'permit'), or, where no permitted works is within 150 m,
-- a final-effluent monitoring point (attrs.works = 'monitoring point'). A permitted works borrows the nearest monitoring point within 150 m (attrs.monitor_site_id).
update geo.site set attrs = attrs - 'works' - 'monitor_site_id' - 'measured' where kind = 'sewage_works' and attrs ?| array['works', 'monitor_site_id', 'measured'];

update geo.site set attrs = attrs || '{"works": "permit", "measured": false}'
where kind = 'sewage_works' and attrs->>'permit_type' = 'WwTW/Sewage Treatment Works (water company)';

update geo.site m set attrs = m.attrs || '{"works": "monitoring point", "measured": true}'
where m.kind = 'sewage_works' and m.attrs->>'wq_type' like 'SEWAGE DISCHARGES - FINAL/TREATED EFFLUENT - WATER COMPANY%'
  and not exists (select 1 from geo.site w where w.kind = 'sewage_works' and w.attrs->>'works' = 'permit'
                  and w.geom_bng && ST_Expand(m.geom_bng, 150) and ST_DWithin(w.geom_bng, m.geom_bng, 150));

update geo.site w set attrs = w.attrs || jsonb_build_object('monitor_site_id', x.mid, 'measured', true)
from (select distinct on (w2.id) w2.id wid, m.id mid from geo.site w2
      join geo.site m on m.kind = 'sewage_works' and m.attrs->>'wq_type' like 'SEWAGE DISCHARGES - FINAL/TREATED EFFLUENT - WATER COMPANY%'
                     and m.geom_bng && ST_Expand(w2.geom_bng, 150) and ST_DWithin(m.geom_bng, w2.geom_bng, 150)
      where w2.kind = 'sewage_works' and w2.attrs->>'works' = 'permit' order by w2.id, ST_Distance(m.geom_bng, w2.geom_bng)) x
where x.wid = w.id;

-- nearest watercourse for works that were not snapped
update geo.site w set river_id = n.river_id, waterbody_id = coalesce(w.waterbody_id, n.waterbody_id)
from (select w2.id wid, l.river_id, l.waterbody_id from geo.site w2
      cross join lateral (select river_id, waterbody_id from geo.river_link order by geom_bng <-> w2.geom_bng limit 1) l
      where w2.kind = 'sewage_works' and w2.attrs ? 'works' and w2.river_id is null and w2.geom_bng is not null) n
where n.wid = w.id;

select live.refresh_works();
select attrs->>'works' works, count(*), count(*) filter (where (attrs->>'measured')::boolean) measured from geo.site where kind = 'sewage_works' and attrs ? 'works' group by 1;
