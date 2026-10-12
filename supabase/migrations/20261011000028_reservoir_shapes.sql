-- Reservoirs are shapes, not points. Base layer, always on, thinned by area as you zoom out.
create table core.reservoir (
  id         bigint generated always as identity primary key,
  name       text not null,
  geom       geometry(MultiPolygon,4326) not null,
  label_pt   geometry(Point,4326),
  area_km2   double precision not null,
  river_id   bigint references core.river(id),
  source_id  bigint not null references ingest.source(id),
  source_key text not null,
  attrs      jsonb not null default '{}',
  unique (source_id, source_key)
);
create index on core.reservoir using gist (geom);
create index on core.reservoir (river_id);
create index on core.reservoir (source_id);
alter table core.reservoir enable row level security;
create policy public_read on core.reservoir for select to anon, authenticated using (true);

update core.map_layer set geom_kind = 'polygon', grp = 'base', default_on = true, min_zoom = 4, cluster_below = null, hot_only_below = null, max_features = 1500,
  note = 'named OSM reservoirs as outlines; large ones when zoomed out, all of them at street level' where code = 'reservoirs';
insert into core.map_zoom_rule (layer, from_zoom, threshold) values ('reservoirs', 0, 8), ('reservoirs', 6, 2), ('reservoirs', 8, 0.4), ('reservoirs', 9, 0.1), ('reservoirs', 10, 0);

-- reservoirs leave the point view
create or replace view core.map_point as
select 'overflows'::text as layer, s.id, s.geom, (st.status = 'discharging') as hot,
       jsonb_build_object('n', s.name, 'co', org.name, 'st', coalesce(st.status, 'unknown'), 'since', st.status_since, 'rw', o.receiving_water_raw,
                          'rv', r.slug, 'rn', r.name, 'sp', a.spill_count, 'hr', round(a.total_duration_hr::numeric), 'rep', st.reported_at, 'ls', st.last_event_start, 'le', st.last_event_end) as props
from core.site s join core.overflow o on o.site_id = s.id
left join core.overflow_status st on st.site_id = s.id left join ref.organisation org on org.id = o.company_id
left join core.river r on r.id = s.river_id left join core.discharge_annual a on a.site_id = s.id and a.year = 2025
where s.kind = 'storm_overflow' and s.merged_into is null
union all
select 'bathing', s.id, s.geom, coalesce(ba.classification = 'poor', false),
       jsonb_build_object('n', s.name, 'wt', s.attrs->>'water_type', 'cl', ba.classification, 'cy', ba.year, 'at', ec.observed_at, 'ec', ec.value, 'cn', ec.censor, 'rv', r.slug, 'rn', r.name)
from core.site s
left join lateral (select classification, year from core.bathing_assessment b where b.site_id = s.id order by year desc limit 1) ba on true
left join lateral (select o.observed_at, o.value, o.censor from core.series se join core.observation o on o.series_id = se.id
                   where se.site_id = s.id and se.source_series_key like 'bwq:%:ecoli' order by o.observed_at desc limit 1) ec on true
left join core.river r on r.id = s.river_id
where s.kind = 'bathing_water' and s.merged_into is null
union all
select 'gauges', s.id, s.geom, (g.pct_of_record <= 0.1 or g.pct_of_record >= 0.9),
       jsonb_build_object('n', s.name, 'q', round(g.value::numeric, 3), 'p', round((g.pct_of_record * 100)::numeric), 'nr', g.n_record, 'at', g.observed_at, 'rv', r.slug, 'rn', r.name)
from core.gauge_flow_now g join core.site s on s.id = g.site_id left join core.river r on r.id = s.river_id
union all
select case p.kind when 'beach' then 'beaches' when 'bridge' then 'bridges' when 'reservoir' then 'reservoirs' end, p.id, p.geom, false,
       jsonb_build_object('n', p.name, 'rv', r.slug, 'rn', r.name, 'wb', w.name)
from core.poi p left join core.river r on r.id = p.river_id left join core.waterbody w on w.id = p.waterbody_id
where p.kind = 'bridge' or (p.kind = 'beach' and p.bathing_site_id is null);

delete from core.poi where kind = 'reservoir';

create or replace function api.map_tile(p_layer text, z int, x int, y int) returns jsonb
language plpgsql stable security definer set search_path = core, ref, public, pg_temp as $$
declare
  env geometry; box geometry; dpp double precision := 360.0 / (256 * power(2, z)); tol double precision := dpp * 0.8;
  dg int := case when z <= 5 then 3 when z <= 9 then 4 else 5 end;
  lay core.map_layer; feats jsonb; capped boolean := false; n int; cell double precision; ord int;
begin
  select * into lay from core.map_layer where code = p_layer;
  if not found then return jsonb_build_object('type','FeatureCollection','features','[]'::jsonb); end if;
  if z < lay.min_zoom then return jsonb_build_object('type','FeatureCollection','features','[]'::jsonb,'below_min_zoom',true); end if;
  env := ST_Transform(ST_TileEnvelope(z, x, y), 4326);
  box := ST_Expand(env, dpp * 24);                                  -- 24 px margin so symbols and labels at the edge are not cut

  if p_layer = 'country' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', b.name),
             'geometry', ST_AsGeoJSON(case when z <= 5 then b.geom_lo else b.geom_mid end, dg)::jsonb)), '[]') into feats
    from core.boundary b where b.kind = 'country' and b.geom && box;

  elsif p_layer = 'national_parks' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', b.name, 'lx', ST_X(b.label_pt), 'ly', ST_Y(b.label_pt)),
             'geometry', ST_AsGeoJSON(case when z <= 6 then b.geom_lo when z <= 9 then b.geom_mid else ST_SimplifyPreserveTopology(b.geom, tol) end, dg)::jsonb)), '[]') into feats
    from core.boundary b where b.kind = 'national_park' and b.geom && box;

  elsif p_layer = 'urban' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'm', q.major, 'a', round(q.area_km2::numeric,1), 'lx', q.lx, 'ly', q.ly),
             'geometry', ST_AsGeoJSON(q.g, dg)::jsonb)), '[]'), count(*) into feats, n
    from (select b.name, (b.attrs->>'is_major') = 'true' as major, b.area_km2, ST_X(b.label_pt) lx, ST_Y(b.label_pt) ly,
                 case when z <= 6 then b.geom_lo when z <= 9 then b.geom_mid else ST_SimplifyPreserveTopology(b.geom, tol) end as g
          from core.boundary b
          where b.kind = 'urban_area' and b.geom && box
            and (z >= 8 or (z >= 6 and b.rank <= 3) or (z >= 4 and (b.attrs->>'is_major') = 'true'))
          order by b.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'network' then
    -- minimum stream order rises as you zoom out, so only the major rivers are drawn nationally
    ord := coalesce((select r.threshold from core.map_zoom_rule r where r.layer = 'network' and r.from_zoom <= z order by r.from_zoom desc limit 1), 0)::int;
    execute format($q$
      select coalesce(jsonb_agg(f), '[]'), count(*) from (
        select jsonb_build_object('type','Feature',
                 'properties', jsonb_strip_nulls(jsonb_build_object('o', l.size_class, 'r', r.slug, 'w', ms.waterbody_id, 'n', coalesce(ms.name, r.name), 's', ms.s, 't', ms.t)),
                 'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, $1), $2)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id left join core.waterbody_map_state ms on ms.waterbody_id = l.waterbody_id
        where l.river_class >= %s and l.geom && $3 order by l.river_class desc, l.size_class desc limit $4) q $q$, ord)
      into feats, n using tol, dg, box, lay.max_features;
    capped := n >= lay.max_features;

  elsif p_layer = 'river_labels' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'km', q.km),'geometry',ST_AsGeoJSON(q.label_pt, dg)::jsonb)), '[]'), count(*) into feats, n
    from (select r.name, round(r.length_km::numeric) km, r.label_pt from core.river r
          where r.label_pt && box and r.length_km >= coalesce((select q.threshold from core.map_zoom_rule q where q.layer = 'river_labels' and q.from_zoom <= z order by q.from_zoom desc limit 1), 0)
          order by r.length_km desc limit lay.max_features) q;

  elsif p_layer = 'reservoirs' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'a', round(q.area_km2::numeric, 2), 'lx', ST_X(q.label_pt), 'ly', ST_Y(q.label_pt)),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(q.geom, tol), dg)::jsonb)), '[]'), count(*) into feats, n
    from (select r.name, r.area_km2, r.label_pt, r.geom from core.reservoir r
          where r.geom && box and r.area_km2 >= coalesce((select z2.threshold from core.map_zoom_rule z2 where z2.layer = 'reservoirs' and z2.from_zoom <= z order by z2.from_zoom desc limit 1), 0)
          order by r.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'place_labels' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', b.name),'geometry',ST_AsGeoJSON(b.label_pt, dg)::jsonb)), '[]') into feats
    from core.boundary b where b.kind = 'city' and b.label_pt && box;

  else  -- point layers
    if lay.hot_only_below is not null and z < lay.hot_only_below then
      -- zoomed out: only what is urgent (e.g. overflows discharging now, flow extremes), never a swarm
      select coalesce(jsonb_agg(jsonb_build_object('type','Feature','id', q.id,'properties', q.props || jsonb_build_object('hot', true),'geometry',ST_AsGeoJSON(q.geom, dg)::jsonb)), '[]'), count(*) into feats, n
      from (select m.id, m.geom, m.props from core.map_point m where m.layer = p_layer and m.hot and m.geom && box order by m.id limit lay.max_features) q;
      capped := n >= lay.max_features;
    elsif lay.cluster_below is not null and z < lay.cluster_below then
      cell := dpp * 56;                                              -- one cluster per ~56 px cell
      select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('c', q.n, 'h', q.h),'geometry',ST_AsGeoJSON(q.c, dg)::jsonb)), '[]') into feats
      from (select ST_Centroid(ST_Collect(m.geom)) c, count(*) n, count(*) filter (where m.hot) h
            from core.map_point m where m.layer = p_layer and m.geom && box group by ST_SnapToGrid(m.geom, cell, cell)) q;
    else
      select coalesce(jsonb_agg(jsonb_build_object('type','Feature','id', q.id,'properties', q.props || jsonb_build_object('hot', q.hot),'geometry',ST_AsGeoJSON(q.geom, dg)::jsonb)), '[]'), count(*) into feats, n
      from (select m.id, m.geom, m.hot, m.props from core.map_point m where m.layer = p_layer and m.geom && box order by m.hot desc, m.id limit lay.max_features) q;
      capped := n >= lay.max_features;
    end if;
  end if;

  perform set_config('response.headers', '[{"Cache-Control":"public, max-age=30"}]', true);
  return jsonb_build_object('type','FeatureCollection','features', coalesce(feats,'[]'), 'truncated', capped);
end $$;

