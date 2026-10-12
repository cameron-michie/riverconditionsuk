-- Density rules as data. network.threshold = minimum river_class; river_labels.threshold = minimum river length in km. Applies from `from_zoom` upward.
create table core.map_zoom_rule (layer text not null references core.map_layer(code), from_zoom smallint not null, threshold numeric not null, primary key (layer, from_zoom));
alter table core.map_zoom_rule enable row level security;
create policy public_read on core.map_zoom_rule for select to anon, authenticated using (true);
insert into core.map_zoom_rule (layer, from_zoom, threshold) values
  ('network', 0, 10), ('network', 7, 9), ('network', 8, 8), ('network', 9, 7), ('network', 10, 6), ('network', 11, 4), ('network', 12, 2), ('network', 13, 0),
  ('river_labels', 0, 200), ('river_labels', 4, 150), ('river_labels', 5, 100), ('river_labels', 6, 70), ('river_labels', 7, 50), ('river_labels', 8, 35), ('river_labels', 9, 22), ('river_labels', 10, 12), ('river_labels', 11, 6), ('river_labels', 12, 2), ('river_labels', 13, 0);

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
             'geometry', ST_AsGeoJSON(case when z <= 6 then b.geom_lo when z <= 10 then b.geom_mid else b.geom end, dg)::jsonb)), '[]') into feats
    from core.boundary b where b.kind = 'national_park' and b.geom && box;

  elsif p_layer = 'urban' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'm', q.major, 'a', round(q.area_km2::numeric,1), 'lx', q.lx, 'ly', q.ly),
             'geometry', ST_AsGeoJSON(q.g, dg)::jsonb)), '[]'), count(*) into feats, n
    from (select b.name, (b.attrs->>'is_major') = 'true' as major, b.area_km2, ST_X(b.label_pt) lx, ST_Y(b.label_pt) ly,
                 case when z <= 6 then b.geom_lo when z <= 9 then b.geom_mid else b.geom end as g
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

