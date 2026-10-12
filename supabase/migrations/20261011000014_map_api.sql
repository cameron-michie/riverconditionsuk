-- Zoom-aware map API. The browser asks for slippy-map tiles (z/x/y); Postgres decides what a tile contains at that zoom:
-- geometry simplification, minimum stream order, point clustering, caps. A future satellite layer is a registry row plus a branch here.

create index river_link_g6 on core.river_link using gist (geom) where strahler >= 6;
create index river_link_g5 on core.river_link using gist (geom) where strahler >= 5;
create index river_link_g4 on core.river_link using gist (geom) where strahler >= 4;
create index river_link_g3 on core.river_link using gist (geom) where strahler >= 3;
create index river_link_g2 on core.river_link using gist (geom) where strahler >= 2;

-- every point layer as one shape: (layer, id, geom, hot, props). `hot` = worth drawing first / counting in a cluster.
create view core.map_point as
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
select p.kind || 's', p.id, p.geom, false,
       jsonb_build_object('n', p.name, 'rv', r.slug, 'rn', r.name, 'wb', w.name)
from core.poi p left join core.river r on r.id = p.river_id left join core.waterbody w on w.id = p.waterbody_id
where p.kind in ('bridge','reservoir') or (p.kind = 'beach' and p.bathing_site_id is null);

create function api.map_tile(p_layer text, z int, x int, y int) returns jsonb
language plpgsql stable security definer set search_path = core, ref, public, pg_temp as $$
declare
  env geometry; box geometry; dpp double precision := 360.0 / (256 * power(2, z)); tol double precision := dpp * 0.8;
  dg int := case when z <= 5 then 3 when z <= 9 then 4 else 5 end;
  lay core.map_layer; feats jsonb; capped boolean := false; n int; cell double precision;
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

  elsif p_layer = 'waterbodies' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','id', q.id,
             'properties', jsonb_build_object('id', q.id, 'n', q.name, 'r', q.slug, 's', q.s),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(q.line_geom, tol), dg)::jsonb)), '[]'), count(*) into feats, n
    from (select w.id, w.name, w.line_geom, r.slug,
                 coalesce((select jsonb_object_agg(s.signal_code, jsonb_build_array(s.state_rank, case s.trend when 'improving' then 1 when 'worsening' then -1 else 0 end))
                           from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = w.id), '{}') s
          from core.waterbody w left join core.waterbody_river wr on wr.waterbody_id = w.id left join core.river r on r.id = wr.river_id
          where w.line_geom is not null and w.line_geom && box limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'network' then
    -- minimum stream order by zoom; literal predicates so the partial GiST indexes apply
    if z <= 4 then
      select jsonb_agg(f), count(*) into feats, n from (select jsonb_build_object('type','Feature','properties',jsonb_build_object('r', r.slug,'o', l.strahler),'geometry',ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, tol), dg)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id where l.strahler >= 6 and l.geom && box order by l.strahler desc limit lay.max_features) q;
    elsif z <= 6 then
      select jsonb_agg(f), count(*) into feats, n from (select jsonb_build_object('type','Feature','properties',jsonb_build_object('r', r.slug,'o', l.strahler),'geometry',ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, tol), dg)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id where l.strahler >= 5 and l.geom && box order by l.strahler desc limit lay.max_features) q;
    elsif z = 7 then
      select jsonb_agg(f), count(*) into feats, n from (select jsonb_build_object('type','Feature','properties',jsonb_build_object('r', r.slug,'o', l.strahler),'geometry',ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, tol), dg)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id where l.strahler >= 4 and l.geom && box order by l.strahler desc limit lay.max_features) q;
    elsif z = 8 then
      select jsonb_agg(f), count(*) into feats, n from (select jsonb_build_object('type','Feature','properties',jsonb_build_object('r', r.slug,'o', l.strahler),'geometry',ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, tol), dg)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id where l.strahler >= 3 and l.geom && box order by l.strahler desc limit lay.max_features) q;
    elsif z = 9 then
      select jsonb_agg(f), count(*) into feats, n from (select jsonb_build_object('type','Feature','properties',jsonb_build_object('r', r.slug,'o', l.strahler),'geometry',ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, tol), dg)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id where l.strahler >= 2 and l.geom && box order by l.strahler desc limit lay.max_features) q;
    else
      select jsonb_agg(f), count(*) into feats, n from (select jsonb_build_object('type','Feature','properties',jsonb_build_object('r', r.slug,'o', l.strahler),'geometry',ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, tol), dg)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id where l.geom && box order by l.strahler desc limit lay.max_features * 2) q;
    end if;
    feats := coalesce(feats, '[]'); capped := n >= lay.max_features;

  else  -- point layers
    if lay.cluster_below is not null and z < lay.cluster_below then
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

-- Everything the UI needs to configure itself: layers, signal ladders and wording, evidence labels.
create function api.ui_config() returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object(
    'layers',   (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'group', grp, 'kind', geom_kind, 'min_zoom', min_zoom, 'cluster_below', cluster_below, 'on', default_on) order by sort) from core.map_layer),
    'signals',  (select jsonb_agg(jsonb_build_object('code', code, 'label', short_label, 'words', words, 'pressure', is_pressure, 'about', description) order by sort) from core.signal_def),
    'evidence', (select jsonb_object_agg(code, jsonb_build_object('label', label, 'about', description)) from ref.evidence_class_def));
$$;

-- Whole river as one line, tidal reaches included.
create function api.river_geom(p_slug text) returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object('type','Feature','properties',jsonb_build_object('slug', r.slug, 'name', r.name, 'bbox', array[ST_XMin(r.geom), ST_YMin(r.geom), ST_XMax(r.geom), ST_YMax(r.geom)]),
         'geometry', ST_AsGeoJSON(r.geom, 5)::jsonb)
  from core.river r where r.slug = p_slug and r.geom is not null;
$$;

grant execute on function api.map_tile(text,int,int,int), api.ui_config(), api.river_geom(text) to anon, authenticated;
