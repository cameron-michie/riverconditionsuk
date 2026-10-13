-- api: the functions the web app calls (web/app.js). The only exposed schema. Every function is security definer with an empty search_path,
-- reads geo, live and ref, and returns jsonb. Response keys are part of the frontend contract.

-- Every map point, one row per feature, with the compact properties the tiles carry. Not exposed: read by map_tile, area_summary and the dossiers.
create view live.map_point as
  select 'overflows'::text layer, s.id, s.geom, coalesce(n.state = 'discharging', false) hot,
         jsonb_build_object('n', s.name, 'co', org.name, 'st', coalesce(n.state, 'unknown'), 'since', n.since, 'rw', s.attrs->>'receiving', 'rv', r.slug, 'rn', r.name,
                            'sp', (s.attrs->>'spills')::int, 'hr', round((s.attrs->>'spill_hours')::numeric), 'rep', n.at, 'ls', n.detail->'last_event_start', 'le', n.detail->'last_event_end',
                            'mon', coalesce(n.state in ('discharging', 'not_discharging'), false)) props
  from geo.site s left join live.site_now n on n.site_id = s.id
  left join ref.organisation org on org.id = s.operator_id left join geo.river r on r.id = s.river_id
  where s.kind = 'storm_overflow'
  union all
  select 'bathing', s.id, s.geom, coalesce(s.attrs->>'class' = 'poor', false),
         jsonb_build_object('n', s.name, 'wt', s.attrs->>'water_type', 'cl', s.attrs->>'class', 'cy', (s.attrs->>'class_year')::int, 'at', ec.latest_at, 'ec', ec.latest_value, 'cn', ec.latest_censor, 'rv', r.slug, 'rn', r.name)
  from geo.site s
  left join lateral (select se.latest_at, se.latest_value, se.latest_censor from live.series se where se.site_id = s.id and se.source_series_key like 'bwq:%:ecoli' order by se.latest_at desc nulls last limit 1) ec on true
  left join geo.river r on r.id = s.river_id
  where s.kind = 'bathing_water'
  union all
  select 'gauges', s.id, s.geom, g.rank >= 3,
         jsonb_build_object('n', s.name, 'b', g.rank, 'bd', g.state, 'lv', round(g.stage::numeric, 2), 'th', (g.detail->>'typical_high')::float8, 'ix', round((g.detail->>'level_index')::numeric, 2),
                            'q', round(g.flow::numeric, 3), 'qi', round((g.detail->>'flow_index')::numeric, 2), 'p', round(g.flow_pct::numeric), 'at', g.at, 'rv', r.slug, 'rn', r.name)
  from live.site_now g join geo.site s on s.id = g.site_id left join geo.river r on r.id = s.river_id
  where g.kind = 'gauge'
  union all
  select 'bridges', s.id, s.geom, false, jsonb_build_object('n', s.name, 'rv', r.slug, 'rn', r.name, 'wb', w.name)
  from geo.site s left join geo.river r on r.id = s.river_id left join geo.waterbody w on w.id = s.waterbody_id
  where s.kind = 'bridge'
  union all
  select 'sewage_works', s.id, s.geom, false,
         jsonb_strip_nulls(jsonb_build_object('n', s.name, 'co', org.name, 'rw', s.river_name_raw, 'm', coalesce((s.attrs->>'measured')::boolean, false), 'pm', s.attrs->>'permit_ref', 'rv', r.slug, 'rn', r.name,
                            'at', n.at, 'nh', n.detail#>>'{latest,ammonia_total_n,v}', 'nhc', n.detail#>>'{latest,ammonia_total_n,c}', 'bod', n.detail#>>'{latest,bod5,v}',
                            'ss', n.detail#>>'{latest,suspended_solids,v}', 'tp', n.detail#>>'{latest,phosphorus_total,v}'))
  from geo.site s left join live.site_now n on n.site_id = s.id and n.kind = 'works'
  left join ref.organisation org on org.id = s.operator_id left join geo.river r on r.id = s.river_id
  where s.kind = 'sewage_works' and s.attrs ? 'works'
  union all
  select 'citizen', s.id, s.geom, false,
         jsonb_strip_nulls(jsonb_build_object('n', s.name, 'org', s.attrs->>'organisation', 'at', v.last_visit, 'nv', v.visits, 'p', round(ph.latest_value::numeric, 3), 'rv', r.slug, 'rn', r.name))
  from geo.site s
  join lateral (select max(sv.surveyed_at) last_visit, count(*) visits from live.survey sv where sv.site_id = s.id and sv.kind = 'citizen_weekly') v on true
  left join lateral (select se.latest_value from live.series se join ref.parameter p on p.id = se.parameter_id
                     where se.site_id = s.id and p.code = 'phosphorus_reactive' and se.evidence_class = 'citizen_science' order by se.latest_at desc nulls last limit 1) ph on true
  left join geo.river r on r.id = s.river_id
  where s.kind = 'survey_site' and v.visits > 0;

-- the latest flood outlook codes for an area, as 'VL,L,M,H,..' by day
create function live.outlook_days(p_area bigint)
returns text
language sql
stable
set search_path = ''
as $$
  select string_agg(f.risk, ',' order by f.day) from live.flood f where f.kind = 'outlook' and f.area_id = p_area;
$$;

create function api.ui_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'layers',   (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'group', grp, 'kind', geom_kind, 'min_zoom', min_zoom, 'cluster_below', cluster_below, 'hot_only_below', hot_only_below,
                                                     'on', default_on, 'labels', has_labels, 'labels_on', labels_default) order by sort) from ref.map_layer),
    'signals',  (select jsonb_agg(jsonb_build_object('code', code, 'label', short_label, 'words', words, 'pressure', is_pressure, 'about', description) order by sort) from ref.signal),
    'evidence', (select jsonb_object_agg(code, jsonb_build_object('label', label, 'about', about)) from ref.term where domain = 'evidence_class'),
    'flood',    jsonb_build_object('bands', jsonb_build_array('low','normal','elevated','high','severe'),
                  'rules', (select jsonb_agg(jsonb_build_object('kind', kind, 'from', from_value, 'band', band, 'about', about) order by kind, from_value) from ref.band where kind in ('level', 'flow')),
                  'risk', jsonb_build_object('VL', 'very low', 'L', 'low', 'M', 'medium', 'H', 'high')));
$$;

create function api.map_tile(p_layer text, z integer, x integer, y integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  env public.geometry; box public.geometry; dpp double precision := 360.0 / (256 * power(2, z)); tol double precision := dpp * 0.8;
  dg int := case when z <= 5 then 3 when z <= 9 then 4 else 5 end;
  lay ref.map_layer; feats jsonb; capped boolean := false; n int; cell double precision; ord int;
begin
  select * into lay from ref.map_layer where code = p_layer;
  if not found then return jsonb_build_object('type','FeatureCollection','features','[]'::jsonb); end if;
  if z < lay.min_zoom then return jsonb_build_object('type','FeatureCollection','features','[]'::jsonb,'below_min_zoom',true); end if;
  env := public.ST_Transform(public.ST_TileEnvelope(z, x, y), 4326);
  box := public.ST_Expand(env, dpp * 24);                                  -- 24 px margin so symbols and labels at the edge are not cut

  if p_layer = 'country' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', b.name),
             'geometry', public.ST_AsGeoJSON(case when z <= 5 then b.geom_lo else b.geom_mid end, dg)::jsonb)), '[]') into feats
    from geo.area b where b.kind = 'country' and b.geom && box;

  elsif p_layer = 'national_parks' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', b.name, 'lx', public.ST_X(b.label_pt), 'ly', public.ST_Y(b.label_pt)),
             'geometry', public.ST_AsGeoJSON(case when z <= 6 then b.geom_lo when z <= 9 then b.geom_mid else public.ST_SimplifyPreserveTopology(b.geom, tol) end, dg)::jsonb)), '[]') into feats
    from geo.area b where b.kind = 'national_park' and b.geom && box;

  elsif p_layer = 'urban' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'm', q.major, 'a', round(q.area_km2::numeric,1), 'lx', q.lx, 'ly', q.ly),
             'geometry', public.ST_AsGeoJSON(q.g, dg)::jsonb)), '[]'), count(*) into feats, n
    from (select b.name, (b.attrs->>'is_major') = 'true' as major, b.area_km2, public.ST_X(b.label_pt) lx, public.ST_Y(b.label_pt) ly,
                 case when z <= 6 then b.geom_lo when z <= 9 then b.geom_mid else public.ST_SimplifyPreserveTopology(b.geom, tol) end as g
          from geo.area b
          where b.kind = 'urban_area' and b.geom && box
            and (z >= 8 or (z >= 6 and b.rank <= 3) or (z >= 4 and (b.attrs->>'is_major') = 'true'))
          order by b.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'network' then
    -- minimum stream class rises as you zoom out, so only the major rivers are drawn nationally
    ord := ref.zoom_threshold('network', z)::int;
    execute format($q$
      select coalesce(jsonb_agg(f), '[]'), count(*) from (
        select jsonb_build_object('type','Feature',
                 'properties', jsonb_strip_nulls(jsonb_build_object('o', l.size_class, 'r', r.slug, 'w', ms.waterbody_id, 'n', coalesce(wb.name, r.name), 's', ms.s, 't', ms.t, 'k', wb.length_km)),
                 'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(l.geom, $1), $2)::jsonb) f
        from geo.river_link l left join geo.river r on r.id = l.river_id
        left join live.waterbody_now ms on ms.waterbody_id = l.waterbody_id left join geo.waterbody wb on wb.id = l.waterbody_id
        where l.river_class >= %s and l.geom && $3 order by l.river_class desc, l.size_class desc limit $4) q $q$, ord)
      into feats, n using tol, dg, box, lay.max_features;
    capped := n >= lay.max_features;

  elsif p_layer = 'river_labels' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'km', q.km),'geometry',public.ST_AsGeoJSON(q.label_pt, dg)::jsonb)), '[]'), count(*) into feats, n
    from (select r.name, round(r.length_km::numeric) km, r.label_pt from geo.river r
          where r.label_pt && box
            and r.river_class >= ref.zoom_threshold('network', z)       -- only rivers that are drawn at this zoom
            and r.length_km >= ref.zoom_threshold('river_labels', z)
          order by r.length_km desc limit lay.max_features) q;

  elsif p_layer = 'water' then
    -- natural water drawn at true size (like the towns), thinned by area as you zoom out
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_strip_nulls(jsonb_build_object('n', q.name, 'k', q.kind, 'a', round(q.area_km2::numeric, 3), 'lx', public.ST_X(q.label_pt), 'ly', public.ST_Y(q.label_pt))),
             'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(q.geom, tol), dg)::jsonb)), '[]'), count(*) into feats, n
    from (select w.name, w.attrs->>'kind' kind, w.area_km2, w.label_pt, w.geom from geo.area w
          where w.kind = 'water' and w.geom && box and w.area_km2 >= ref.zoom_threshold('water', z)
          order by w.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'beaches' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_strip_nulls(jsonb_build_object('n', q.name, 'a', round(q.area_km2::numeric, 4), 'lx', public.ST_X(q.label_pt), 'ly', public.ST_Y(q.label_pt))),
             'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(q.geom, tol * 0.5), dg)::jsonb)), '[]'), count(*) into feats, n
    from (select b.name, b.area_km2, b.label_pt, b.geom from geo.area b where b.kind = 'beach' and b.geom && box order by b.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'flood_outlook' then
    -- Flood Forecasting Centre five-day outlook: r = worst risk over the five days (0 very low .. 3 high), d = the five daily codes
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('n', q.name, 'r', q.r, 'd', q.d, 'lx', public.ST_X(q.label_pt), 'ly', public.ST_Y(q.label_pt)),
             'geometry', public.ST_AsGeoJSON(case when z <= 6 then q.geom_lo when z <= 9 then q.geom_mid else public.ST_SimplifyPreserveTopology(q.geom, tol) end, dg)::jsonb)), '[]') into feats
    from (select b.name, b.label_pt, b.geom, b.geom_lo, b.geom_mid,
                 (select max(array_position(array['VL','L','M','H'], f.risk)) - 1 from live.flood f where f.kind = 'outlook' and f.area_id = b.id) r,
                 live.outlook_days(b.id) d
          from geo.area b where b.kind = 'flood_outlook_area' and b.geom && box) q;

  elsif p_layer = 'flood_warnings' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('n', a.name, 'sv', w.severity, 'm', left(w.message, 220)),
             'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(a.geom, tol), dg)::jsonb)), '[]') into feats
    from geo.area a join live.flood w on w.kind = 'warning' and w.area_id = a.id and w.severity < 4
    where a.kind = 'warning_area' and a.geom && box;

  elsif p_layer = 'bridge_areas' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('n', b.name, 'l', (b.attrs->>'length_m')::int),
             'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(b.geom, tol * 0.3), 6)::jsonb)), '[]') into feats
    from geo.area b where b.kind = 'bridge' and b.geom && box;

  elsif p_layer = 'flood_zones' then
    -- the expected flood plain (EA flood zones 2 and 3), present only where a flood risk is active
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('z', q.zone, 'r', q.reason),
             'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(q.geom, tol * 0.6), dg)::jsonb) order by q.zone), '[]') into feats
    from (select f.attrs->>'zone' zone, f.attrs->>'reason' reason, f.geom from geo.area f where f.kind = 'flood_zone' and f.geom && box limit lay.max_features) q;

  elsif p_layer = 'place_labels' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', b.name),'geometry',public.ST_AsGeoJSON(b.label_pt, dg)::jsonb)), '[]') into feats
    from geo.area b where b.kind = 'city' and b.label_pt && box;

  else  -- point layers
    if lay.hot_only_below is not null and z < lay.hot_only_below then
      -- zoomed out: only what is urgent (e.g. overflows discharging now, flow extremes), never a swarm
      select coalesce(jsonb_agg(jsonb_build_object('type','Feature','id', q.id,'properties', q.props || jsonb_build_object('hot', true),'geometry',public.ST_AsGeoJSON(q.geom, dg)::jsonb)), '[]'), count(*) into feats, n
      from (select m.id, m.geom, m.props from live.map_point m where m.layer = p_layer and m.hot and m.geom && box order by m.id limit lay.max_features) q;
      capped := n >= lay.max_features;
    elsif lay.cluster_below is not null and z < lay.cluster_below then
      cell := dpp * 56;                                              -- one cluster per ~56 px cell
      select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('c', q.n, 'h', q.h),'geometry',public.ST_AsGeoJSON(q.c, dg)::jsonb)), '[]') into feats
      from (select public.ST_Centroid(public.ST_Collect(m.geom)) c, count(*) n, count(*) filter (where m.hot) h
            from live.map_point m where m.layer = p_layer and m.geom && box group by public.ST_SnapToGrid(m.geom, cell, cell)) q;
    else
      select coalesce(jsonb_agg(jsonb_build_object('type','Feature','id', q.id,'properties', q.props || jsonb_build_object('hot', q.hot),'geometry',public.ST_AsGeoJSON(q.geom, dg)::jsonb)), '[]'), count(*) into feats, n
      from (select m.id, m.geom, m.hot, m.props from live.map_point m where m.layer = p_layer and m.geom && box order by m.hot desc, m.id limit lay.max_features) q;
      capped := n >= lay.max_features;
    end if;
  end if;

  perform set_config('response.headers', '[{"Cache-Control":"public, max-age=30"}]', true);
  return jsonb_build_object('type','FeatureCollection','features', coalesce(feats,'[]'), 'truncated', capped);
end $$;

create function api.area_summary(p_minx double precision, p_miny double precision, p_maxx double precision, p_maxy double precision)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare env public.geometry := public.ST_MakeEnvelope(p_minx, p_miny, p_maxx, p_maxy, 4326); r jsonb;
begin
  if (p_maxx - p_minx) > 4.5 or (p_maxy - p_miny) > 3.5 then
    return jsonb_build_object('too_wide', true);
  end if;
  select jsonb_build_object(
    'overflows', (select jsonb_build_object('n', count(*), 'discharging', count(*) filter (where props->>'st' = 'discharging'), 'offline', count(*) filter (where props->>'st' = 'offline'),
        'spills_2025', coalesce(sum((props->>'sp')::int), 0),
        'worst', (select coalesce(jsonb_agg(jsonb_build_object('n', w.props->>'n', 'co', w.props->>'co', 'sp', (w.props->>'sp')::int, 'hr', (w.props->>'hr')::int, 'st', w.props->>'st', 'x', public.ST_X(w.geom), 'y', public.ST_Y(w.geom))), '[]')
                  from (select * from live.map_point m2 where m2.layer = 'overflows' and m2.geom && env and m2.props->>'sp' is not null order by (m2.props->>'sp')::int desc limit 5) w))
      from live.map_point m where m.layer = 'overflows' and m.geom && env),
    'stretches', (select coalesce(jsonb_object_agg(z.code, z.arr), '{}') from (
        select d.code, jsonb_agg(c.cnt order by k) arr
        from ref.signal d cross join generate_series(0, 5) k
        cross join lateral (select count(*) cnt from geo.waterbody w join live.waterbody_now ms on ms.waterbody_id = w.id
                            where w.line_geom && env and substr(ms.s, d.sort::int, 1)::int = k) c
        group by d.code) z),
    'rivers', (select coalesce(jsonb_agg(jsonb_build_object('slug', q.slug, 'n', q.name, 'km', q.km, 's', q.s) order by q.km desc), '[]')
      from (select r.slug, r.name, round(r.length_km::numeric) km,
                   (select string_agg(coalesce(sg.state_rank::text, '0'), '' order by d.sort) from ref.signal d left join live.signal sg on sg.entity_kind = 'river' and sg.entity_id = r.id and sg.signal_code = d.code) s
            from geo.river r where r.geom && env and r.length_km >= 8 order by r.length_km desc limit 8) q),
    'bathing', (select coalesce(jsonb_agg(jsonb_build_object('n', props->>'n', 'cl', props->>'cl', 'ec', props->>'ec', 'cn', props->>'cn', 'x', public.ST_X(geom), 'y', public.ST_Y(geom))), '[]')
      from (select * from live.map_point where layer = 'bathing' and geom && env order by (props->>'n') limit 8) b),
    'gauges', (select jsonb_build_object('n', count(*), 'bands', (select coalesce(jsonb_object_agg(bd, c), '{}') from (select props->>'bd' bd, count(*) c from live.map_point where layer = 'gauges' and geom && env group by 1) z),
        'extreme', (select coalesce(jsonb_agg(jsonb_build_object('n', e.props->>'n', 'bd', e.props->>'bd', 'q', e.props->>'q', 'lv', e.props->>'lv', 'x', public.ST_X(e.geom), 'y', public.ST_Y(e.geom))), '[]')
                    from (select * from live.map_point g2 where g2.layer = 'gauges' and g2.geom && env order by (g2.props->>'b')::int desc, g2.id limit 4) e))
      from live.map_point g where g.layer = 'gauges' and g.geom && env),
    'works', (select jsonb_build_object('n', count(*), 'measured', count(*) filter (where (props->>'m')::boolean)) from live.map_point where layer = 'sewage_works' and geom && env),
    'outlook', (select coalesce(jsonb_agg(jsonb_build_object('n', q.name, 'd', q.d) order by q.r desc, q.name), '[]') from (
        select b.name, (select max(array_position(array['VL','L','M','H'], f.risk)) from live.flood f where f.kind = 'outlook' and f.area_id = b.id) r, live.outlook_days(b.id) d
        from geo.area b where b.kind = 'flood_outlook_area' and b.geom && env) q),
    'warnings', (select coalesce(jsonb_agg(jsonb_build_object('n', a.name, 'sv', w.severity)), '[]')
        from geo.area a join live.flood w on w.kind = 'warning' and w.area_id = a.id and w.severity < 4 where a.kind = 'warning_area' and a.geom && env),
    'counts', (select coalesce(jsonb_object_agg(layer, n), '{}') from (select layer, count(*) n from live.map_point where layer = 'bridges' and geom && env group by 1) z),
    'parks', (select coalesce(jsonb_agg(name), '[]') from geo.area where kind = 'national_park' and geom && env),
    'towns', (select coalesce(jsonb_agg(name order by area_km2 desc), '[]') from (select name, area_km2 from geo.area where kind = 'urban_area' and label_pt && env order by area_km2 desc limit 6) t)
  ) into r;
  perform set_config('response.headers', '[{"Cache-Control":"public, max-age=30"}]', true);
  return r;
end $$;

create function api.gauge_dossier(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with s as (select * from geo.site where id = p_id), g as (select * from live.site_now where site_id = p_id and kind = 'gauge'),
lvs as (select se.id, se.latest_value from live.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'water_level'
        where se.site_id = p_id and se.latest_at is not null and se.source_id = (select id from ref.source where slug = 'ea_flood_monitoring')
        order by (se.qualifier ilike 'stage') desc, (se.datum = 'mASD') desc, se.latest_at desc limit 1),
fls as (select se.id from live.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'river_flow'
        where se.site_id = p_id and se.latest_at is not null and se.source_id in (select id from ref.source where slug in ('ea_flood_monitoring','ea_hydrology')) order by se.latest_at desc limit 1),
off as (select (select latest_value from lvs) - (select stage from g) o)
select jsonb_build_object(
  'site', (select jsonb_build_object('id', s.id, 'name', s.name, 'river', (select jsonb_build_object('slug', r.slug, 'name', r.name) from geo.river r where r.id = s.river_id),
             'stretch', (select jsonb_build_object('id', w.id, 'name', w.name) from geo.waterbody w where w.id = s.waterbody_id)) from s),
  'state', (select jsonb_build_object('stage', g.stage, 'stage_at', g.detail->'stage_at', 'typical_low', g.detail->'typical_low', 'typical_high', g.detail->'typical_high',
                   'max_on_record', g.detail->'max_on_record', 'highest_recent', g.detail->'highest_recent', 'level_index', g.detail->'level_index', 'level_band', g.detail->'level_band',
                   'flow', g.flow, 'flow_at', g.detail->'flow_at', 'flow_pct', g.flow_pct, 'qmed', g.detail->'qmed', 'flow_q95', g.detail->'flow_q95', 'flow_index', g.detail->'flow_index',
                   'flow_band', g.detail->'flow_band', 'band', g.state, 'band_rank', g.rank) from g),
  'level', (select coalesce(jsonb_agg(jsonb_build_array(t, v) order by t), '[]') from (select distinct on (date_trunc('hour', o.observed_at)) extract(epoch from o.observed_at)::bigint t, round((o.value - coalesce((select o from off), 0))::numeric, 3) v
            from live.observation o where o.series_id = (select id from lvs) and o.observed_at > now() - interval '7 days' and o.value is not null order by date_trunc('hour', o.observed_at), o.observed_at desc) z),
  'flow', (select coalesce(jsonb_agg(jsonb_build_array(t, v) order by t), '[]') from (select distinct on (date_trunc('hour', o.observed_at)) extract(epoch from o.observed_at)::bigint t, round(o.value::numeric, 3) v
            from live.observation o where o.series_id = (select id from fls) and o.observed_at > now() - interval '7 days' and o.value is not null order by date_trunc('hour', o.observed_at), o.observed_at desc) z),
  'outlook', (select jsonb_build_object('area', b.name, 'days', live.outlook_days(b.id), 'issued', (select max(issued_at) from live.flood where kind = 'outlook'))
              from geo.area b, s where b.kind = 'flood_outlook_area' and public.ST_Intersects(b.geom, s.geom) limit 1)
) where exists (select 1 from s);
$$;

create function api.works_dossier(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
select jsonb_build_object(
  'works', jsonb_build_object('id', w.id, 'name', w.name, 'company', org.name, 'permit', w.attrs->>'permit_ref', 'receiving', w.river_name_raw, 'measured', coalesce((w.attrs->>'measured')::boolean, false),
        'basis', w.attrs->>'works', 'x', public.ST_X(w.geom), 'y', public.ST_Y(w.geom),
        'river', (select jsonb_build_object('slug', r.slug, 'name', r.name) from geo.river r where r.id = w.river_id), 'stretch', (select jsonb_build_object('id', b.id, 'name', b.name) from geo.waterbody b where b.id = w.waterbody_id)),
  'latest', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'v', se.latest_value, 'c', se.latest_censor, 'u', u.symbol, 'at', se.latest_at) order by p.code), '[]')
             from live.series se join ref.parameter p on p.id = se.parameter_id join ref.unit u on u.id = se.unit_id
             where se.site_id = coalesce((w.attrs->>'monitor_site_id')::bigint, w.id) and se.matrix = 'effluent' and (se.latest_value is not null or se.latest_censor is not null)),
  'overflows_near', (select coalesce(jsonb_agg(jsonb_build_object('name', m.props->>'n', 'status', m.props->>'st', 'spills', (m.props->>'sp')::int) order by (m.props->>'sp')::int desc nulls last), '[]')
                     from live.map_point m where m.layer = 'overflows' and public.ST_DWithin(m.geom::public.geography, w.geom::public.geography, 500))
) from geo.site w left join ref.organisation org on org.id = w.operator_id where w.id = p_id and w.kind = 'sewage_works' and w.attrs ? 'works';
$$;

create function api.volunteer_dossier(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'site', jsonb_build_object('name', s.name, 'org', s.attrs->>'organisation', 'project', s.attrs->>'project', 'river', case when r.id is not null then jsonb_build_object('slug', r.slug, 'name', r.name) end,
                               'stretch', case when w.id is not null then jsonb_build_object('id', w.id, 'name', w.name) end),
    'visits', (select jsonb_build_object('n', count(*), 'first', min(surveyed_at), 'last', max(surveyed_at)) from live.survey where site_id = s.id and kind = 'citizen_weekly'),
    'latest', (select coalesce(jsonb_agg(jsonb_build_object('param', x.code, 'method', x.method, 'unit', x.unit_id, 'v', x.latest_value, 'at', x.latest_at) order by x.code), '[]') from (
                 select distinct on (p.code, se.method) p.code, se.method, se.unit_id, se.latest_value, se.latest_at
                 from live.series se join ref.parameter p on p.id = se.parameter_id
                 where se.site_id = s.id and se.evidence_class = 'citizen_science' and se.latest_at > now() - interval '400 days' order by p.code, se.method, se.latest_at desc) x),
    'phosphate', (select coalesce(jsonb_agg(jsonb_build_array(round(extract(epoch from o.observed_at) * 1000), round(o.value::numeric, 3)) order by o.observed_at), '[]')
                  from live.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'phosphorus_reactive' join live.observation o on o.series_id = se.id
                  where se.site_id = s.id and se.evidence_class = 'citizen_science' and o.observed_at > now() - interval '365 days' and o.value is not null),
    'notes', (select answers from live.survey where site_id = s.id and kind = 'citizen_weekly' order by surveyed_at desc limit 1))
  from geo.site s left join geo.river r on r.id = s.river_id left join geo.waterbody w on w.id = s.waterbody_id where s.id = p_id and s.kind = 'survey_site';
$$;

create function api.stretch_geom(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('type','Feature','properties',jsonb_build_object('id', w.id, 'bbox', array[public.ST_XMin(w.line_geom), public.ST_YMin(w.line_geom), public.ST_XMax(w.line_geom), public.ST_YMax(w.line_geom)]),
         'geometry', public.ST_AsGeoJSON(public.ST_SimplifyPreserveTopology(w.line_geom, 0.0003), 5)::jsonb)
  from geo.waterbody w where w.id = p_id and w.line_geom is not null;
$$;

create function api.river_geom(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('type','Feature','properties',jsonb_build_object('slug', r.slug, 'name', r.name, 'bbox', array[public.ST_XMin(r.geom), public.ST_YMin(r.geom), public.ST_XMax(r.geom), public.ST_YMax(r.geom)]),
         'geometry', public.ST_AsGeoJSON(r.geom, 5)::jsonb)
  from geo.river r where r.slug = p_slug and r.geom is not null;
$$;

create function api.search_rivers(q text)
returns table (slug text, name text, name_cy text, length_km numeric, parent_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.slug, r.name, r.name_cy, round(r.length_km::numeric, 1), p.name
  from geo.river r left join geo.river p on p.id = r.parent_river_id
  where r.length_km >= 5 and (r.name ilike '%' || q || '%' or r.name_cy ilike '%' || q || '%')
  order by (r.name ilike q || '%' or r.name_cy ilike q || '%') desc, r.length_km desc limit 12;
$$;

create function api.flow_outlook(p_waterbody bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'issued_at', w.flow_issued_at,
    'evidence', 'modelled',
    'area_km2', w.flow_area_km2,
    'days', (select jsonb_agg(jsonb_build_object('at', d->'at', 'pct', round((d->>'pct')::numeric), 'band', r.band, 'label', r.label, 'method', d->'method', 'confidence', d->'confidence', 'sd_z', d->'sd_z',
                                                 'q', round((d->>'q')::numeric, case when (d->>'q')::numeric < 1 then 3 else 2 end), 'q_factor', d->'q_factor') order by d->>'at')
             from jsonb_array_elements(w.flow_days) d
             join lateral (select * from ref.band r where r.kind = 'flow_pct' and r.from_value <= (d->>'pct')::numeric order by r.from_value desc limit 1) r on true))
  from live.waterbody_now w where w.waterbody_id = p_waterbody and w.flow_days is not null;
$$;

create function api.weather(p_at timestamptz default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare at timestamptz := coalesce(p_at, now()); fr record; pr record; out jsonb := '{}';
begin
  -- rain: radar up to now, forecast after. Fall back to whichever exists.
  select * into fr from (
    select 'radar' src, f.* from live.weather f where f.product = 'radar_rain' and at <= now() + interval '20 minutes'
    union all
    select 'forecast', f.* from live.weather f where f.product = 'ifs_rain' and at > now() + interval '20 minutes'
  ) x order by abs(extract(epoch from x.valid_at - at)) limit 1;
  if fr.id is null then
    select 'forecast' src, f.* into fr from live.weather f where f.product in ('ifs_rain', 'radar_rain') order by abs(extract(epoch from f.valid_at - at)) limit 1;
  end if;
  if fr.id is not null then
    out := out || jsonb_build_object('rain', jsonb_build_object('path', fr.path, 'bbox', fr.bbox, 'valid_at', fr.valid_at, 'issued_at', fr.issued_at, 'kind', fr.src,
             'source', case fr.src when 'radar' then 'Met Office radar' else 'ECMWF forecast' end, 'legend', fr.legend));
  end if;
  -- pressure: newest run, nearest step
  select * into pr from live.weather where product = 'ifs_mslp' and issued_at = (select max(issued_at) from live.weather where product = 'ifs_mslp')
    order by abs(extract(epoch from valid_at - at)) limit 1;
  if pr.valid_at is not null then
    out := out || jsonb_build_object('pressure', jsonb_build_object('valid_at', pr.valid_at, 'issued_at', pr.issued_at, 'source', 'ECMWF forecast', 'lines', pr.lines));
  end if;
  -- times the slider can step through: the last radar frames, then forecast steps
  out := out || jsonb_build_object('times', (select coalesce(jsonb_agg(jsonb_build_object('at', valid_at, 'kind', k) order by valid_at), '[]') from (
      select valid_at, 'radar' k from live.weather where product = 'radar_rain'
      union all select valid_at, 'forecast' from live.weather where product = 'ifs_rain' and valid_at > (select coalesce(max(valid_at), now()) from live.weather where product = 'radar_rain')) t));
  return out;
end $$;

create function api.stretch_dossier(p_id bigint)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with w as (select * from geo.waterbody where id = p_id),
rv as (select r.id, r.slug, r.name, r.length_km from w join geo.river r on r.id = w.river_id),
sites as (select s.id from geo.site s join geo.river_link l on l.id = s.river_link_id where l.waterbody_id = p_id),
latest as (
  select distinct on (p.code) p.code, p.name pname, st.name site_name, s.latest_at observed_at, s.latest_value value, s.latest_censor censor, u.symbol
  from geo.site st join live.series s on s.site_id = st.id and s.status = 'active' join ref.parameter p on p.id = s.parameter_id join ref.unit u on u.id = s.unit_id
  where st.id in (select id from sites) and p.code in ('phosphorus_reactive','phosphorus_total','ammonia_total_n','nitrate_n','dissolved_oxygen_sat','dissolved_oxygen_conc','water_temperature','ph','turbidity','conductivity','bod5')
    and s.latest_at is not null and (s.latest_value is not null or s.latest_censor is not null)
  order by p.code, s.latest_at desc),
near as (
  select distinct on (p.code) p.code, p.name pname, st.name site_name, s.latest_at observed_at, s.latest_value value, s.latest_censor censor, u.symbol,
         round((public.ST_Distance(st.geom::public.geography, w.line_geom::public.geography) / 1000)::numeric, 1) dist_km
  from w, geo.site st join live.series s on s.site_id = st.id and s.status = 'active' join ref.parameter p on p.id = s.parameter_id join ref.unit u on u.id = s.unit_id
  where w.line_geom is not null and public.ST_DWithin(st.geom, w.line_geom, 0.05) and st.id not in (select id from sites)
    and public.ST_Distance(st.geom::public.geography, w.line_geom::public.geography) <= 5000
    and p.code in ('phosphorus_reactive','phosphorus_total','ammonia_total_n','nitrate_n','dissolved_oxygen_sat','dissolved_oxygen_conc','water_temperature','ph','turbidity','conductivity','bod5')
    and s.latest_at is not null and (s.latest_value is not null or s.latest_censor is not null)
  order by p.code, s.latest_at desc),
cls as (
  select e.code, e.label, c.value->>'status' as status, (c.value->>'year')::int as year, (c.value->>'cycle')::int as cycle, c.value->>'certainty' as certainty, c.value->>'prev' as prev_status
  from w cross join jsonb_each(w.classes) c join ref.term e on e.domain = 'wfd_element' and e.code = c.key
  where e.code in ('overall','ecological','chemical','phosphate','ammonia','dissolved_oxygen','ph','temperature','fish','invertebrates','macrophytes_phytobenthos','sac_phosphorus')),
ov as (
  select s.id, s.name, org.name company, n.state status, (s.attrs->>'spills')::int spill_count, (s.attrs->>'spill_hours')::numeric total_duration_hr
  from geo.site s left join live.site_now n on n.site_id = s.id left join ref.organisation org on org.id = s.operator_id
  where s.waterbody_id = p_id and s.kind = 'storm_overflow'),
ov_on as (select * from ov where id in (select id from sites))
select jsonb_build_object(
  'stretch', (select jsonb_build_object('id', w.id, 'code', w.wb_code, 'name', w.name, 'category', w.category, 'country', w.country, 'km', round(w.length_km::numeric, 1), 'area_km2', round(w.area_km2::numeric),
                'designation', w.designation, 'upstream_km', (select round(max(upstream_km)::numeric) from geo.river_link where waterbody_id = p_id),
                'catchment', w.operational_catchment, 'river', (select jsonb_build_object('slug', rv.slug, 'name', rv.name, 'km', round(rv.length_km::numeric)) from rv limit 1)) from w),
  'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class, 'summary', s.summary)), '{}')
              from live.signal s where s.entity_kind = 'waterbody' and s.entity_id = p_id),
  'readings', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', pname, 'site', site_name, 'at', observed_at, 'v', value, 'c', censor, 'u', symbol) order by code), '[]') from latest),
  'readings_near', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', pname, 'site', site_name, 'at', observed_at, 'v', value, 'c', censor, 'u', symbol, 'km', dist_km) order by code), '[]') from near),
  'classes', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label, 'status', status, 'year', year, 'cycle', cycle, 'prev', prev_status, 'certainty', certainty)
                order by case code when 'overall' then 0 when 'ecological' then 1 when 'chemical' then 2 else 3 end, code), '[]') from cls),
  'reasons', (select coalesce(jsonb_agg(x), '[]') from (select distinct jsonb_build_object('sector', coalesce(r->>'sector_native', r->>'sector'), 'activity', r->'activity', 'element', e.label, 'certainty', r->'certainty') x
                from w cross join jsonb_array_elements(w.reasons) r left join ref.term e on e.domain = 'wfd_element' and e.code = r->>'element' limit 12) q),
  'apportionment', (select coalesce(jsonb_agg(jsonb_build_object('pollutant', a->'pollutant', 'sector', a->'sector', 'share', (a->>'share_pct')::numeric, 'load_t_yr', (a->>'load_t_yr')::numeric)
                      order by a->>'pollutant', (a->>'share_pct')::numeric desc nulls last), '[]')
                    from w cross join jsonb_array_elements(w.apportionment) a where (a->>'share_pct')::numeric >= 1),
  'overflows', (select jsonb_build_object('n', count(*), 'on_stretch', (select count(*) from ov_on), 'discharging', count(*) filter (where status = 'discharging'), 'offline', count(*) filter (where status = 'offline'),
                  'spills_2025', coalesce(sum(spill_count), 0), 'hours_2025', round(coalesce(sum(total_duration_hr), 0)::numeric),
                  'worst', (select coalesce(jsonb_agg(jsonb_build_object('name', o2.name, 'company', o2.company, 'spills', o2.spill_count, 'hours', round(o2.total_duration_hr::numeric), 'status', o2.status)), '[]')
                            from (select * from ov where spill_count is not null order by spill_count desc limit 5) o2)) from ov),
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'band', g.state, 'stage', round(g.stage::numeric, 2), 'typical_high', (g.detail->>'typical_high')::float8,
                  'level_index', round((g.detail->>'level_index')::numeric, 2), 'flow', round(g.flow::numeric, 3), 'flow_index', round((g.detail->>'flow_index')::numeric, 2), 'pct', round(g.flow_pct::numeric), 'at', g.at)), '[]')
              from live.site_now g join geo.site s on s.id = g.site_id where g.kind = 'gauge' and s.id in (select id from sites)),
  'works', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'measured', coalesce((s.attrs->>'measured')::boolean, false))), '[]')
            from geo.site s where s.waterbody_id = p_id and s.kind = 'sewage_works' and s.attrs ? 'works'),
  'bathing', (select coalesce(jsonb_agg(jsonb_build_object('name', b.props->>'n', 'class', b.props->>'cl', 'year', (b.props->>'cy')::int, 'ecoli', (b.props->>'ec')::float8, 'censor', b.props->>'cn')), '[]')
              from live.map_point b where b.layer = 'bathing' and b.id in (select id from sites)),
  'citizen', (select jsonb_build_object('brw_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
                  'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
                  'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
                  'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach)) from live.survey where waterbody_id = p_id),
  'flow', (select s.basis || jsonb_build_object('summary', s.summary, 'state', s.state, 'rank', s.state_rank) from live.signal s where s.entity_kind = 'waterbody' and s.entity_id = p_id and s.signal_code = 'flow'),
  'outlook', (select jsonb_build_object('area', b.name, 'days', live.outlook_days(b.id))
              from geo.area b, w where b.kind = 'flood_outlook_area' and w.line_geom is not null and public.ST_Intersects(b.geom, public.ST_PointOnSurface(w.line_geom)) limit 1),
  'warnings', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'sv', x.severity, 'message', left(x.message, 300))), '[]')
               from geo.area a join live.flood x on x.kind = 'warning' and x.area_id = a.id and x.severity < 4, w
               where a.kind = 'warning_area' and w.line_geom is not null and public.ST_Intersects(a.geom, w.line_geom)),
  'danger', (select coalesce(jsonb_agg(distinct z.attrs->>'reason'), '[]') from geo.area z, w where z.kind = 'flood_zone' and w.line_geom is not null and public.ST_DWithin(z.geom, w.line_geom, 0.03)),
  'river_signals', (select coalesce(jsonb_object_agg(s.signal_code, s.state_rank), '{}') from live.signal s join rv on s.entity_kind = 'river' and s.entity_id = rv.id)
) where exists (select 1 from w);
$$;

create function api.river_dossier(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
with r as (select * from geo.river where slug = p_slug),
tree as (
  with recursive t as (select id, 0 d from r union all select c.id, t.d + 1 from geo.river c join t on c.parent_river_id = t.id where t.d < 12)
  select id from t),
wbs as (
  select l.waterbody_id, sum(l.length_m) len from geo.river_link l, r where l.river_id = r.id and l.waterbody_id is not null group by 1
  having sum(l.length_m) >= 300),
ov as (
  select s.id, s.name, org.name company, n.state status, (s.attrs->>'spills')::int spill_count, (s.attrs->>'spill_hours')::numeric total_duration_hr, s.attrs->>'receiving' receiving_water_raw
  from geo.site s left join live.site_now n on n.site_id = s.id left join ref.organisation org on org.id = s.operator_id
  where s.kind = 'storm_overflow' and s.river_id in (select id from tree)),
ap as (
  select a->>'pollutant' pollutant, a->>'sector' sector, round(sum((a->>'load_t_yr')::numeric), 2) load_t, sum((a->>'load_t_yr')::numeric) l
  from wbs join geo.waterbody w on w.id = wbs.waterbody_id cross join jsonb_array_elements(w.apportionment) a group by 1, 2),
ap_tot as (select pollutant, sum(l) tl from ap group by 1)
select jsonb_build_object(
  'river', (select jsonb_build_object('slug', r.slug, 'name', r.name, 'name_cy', r.name_cy, 'length_km', round(r.length_km::numeric, 1), 'strahler', r.strahler_max,
              'parent', (select jsonb_build_object('slug', p.slug, 'name', p.name) from geo.river p where p.id = r.parent_river_id),
              'tributaries', (select count(*) - 1 from tree)) from r),
  'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class, 'summary', s.summary)), '{}')
              from live.signal s, r where s.entity_kind = 'river' and s.entity_id = r.id),
  'waterbodies', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'code', w.wb_code, 'name', w.name, 'country', w.country, 'km', round((wbs.len / 1000)::numeric, 1),
        'classes', (select coalesce(jsonb_object_agg(c.key, (c.value->>'status') || ' ' || (c.value->>'year')), '{}') from jsonb_each(w.classes) c
                    where c.key in ('overall','ecological','chemical','phosphate','ammonia','dissolved_oxygen','fish','invertebrates','sac_phosphorus')),
        'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class, 'summary', s.summary)), '{}')
                    from live.signal s where s.entity_kind = 'waterbody' and s.entity_id = w.id),
        'reasons', (select coalesce(jsonb_object_agg(x.sector, x.n), '{}') from (select e->>'sector' sector, count(*) n from jsonb_array_elements(w.reasons) e where e->>'sector' is not null group by 1) x)
      ) order by wbs.len desc), '[]') from wbs join geo.waterbody w on w.id = wbs.waterbody_id),
  'apportionment', (select coalesce(jsonb_agg(jsonb_build_object('pollutant', ap.pollutant, 'sector', ap.sector, 'load_t_yr', ap.load_t, 'share_pct', round((100 * ap.l / nullif(ap_tot.tl, 0))::numeric, 1))
                      order by ap.pollutant, ap.l desc nulls last), '[]')
                    from ap join ap_tot using (pollutant)),
  'overflows', (select jsonb_build_object('count', count(*), 'discharging_now', count(*) filter (where status = 'discharging'), 'offline', count(*) filter (where status = 'offline'),
        'spills_2025', coalesce(sum(spill_count), 0), 'hours_2025', round(coalesce(sum(total_duration_hr), 0)::numeric),
        'worst', (select coalesce(jsonb_agg(jsonb_build_object('site_id', x.id, 'name', x.name, 'company', x.company, 'spills', x.spill_count, 'hours', round(x.total_duration_hr::numeric), 'status', x.status, 'receiving', x.receiving_water_raw)), '[]')
                  from (select * from ov where spill_count is not null order by spill_count desc limit 5) x)) from ov),
  'bathing', (select coalesce(jsonb_agg(jsonb_build_object('name', b.props->>'n', 'class', b.props->>'cl', 'year', (b.props->>'cy')::int, 'ecoli', (b.props->>'ec')::float8, 'censor', b.props->>'cn', 'sampled', b.props->'at')), '[]')
              from live.map_point b where b.layer = 'bathing' and b.props->>'rv' = p_slug),
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'band', x.state, 'stage', round(x.stage::numeric, 2), 'flow', round(x.flow::numeric, 3), 'pct', round(x.flow_pct::numeric), 'at', x.at)), '[]')
             from (select s.id, s.name, g.* from live.site_now g join geo.site s on s.id = g.site_id where g.kind = 'gauge' and s.river_id in (select id from tree) order by g.rank desc, s.name limit 5) x),
  'citizen', (select jsonb_build_object(
        'big_river_watch_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
        'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
        'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
        'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach))
      from live.survey where waterbody_id in (select waterbody_id from wbs)),
  'research', (select r.research from r),
  'outlook', (select coalesce(jsonb_agg(jsonb_build_object('area', q.name, 'days', q.d) order by q.r desc, q.name), '[]') from (
               select b.name, (select max(array_position(array['VL','L','M','H'], f.risk)) from live.flood f where f.kind = 'outlook' and f.area_id = b.id) r, live.outlook_days(b.id) d
               from geo.area b, r where b.kind = 'flood_outlook_area' and r.geom is not null and public.ST_Intersects(b.geom_lo, r.geom) limit 3) q),
  'warnings', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'sv', x.severity, 'message', left(x.message, 300))), '[]')
               from geo.area a join live.flood x on x.kind = 'warning' and x.area_id = a.id and x.severity < 4, r
               where a.kind = 'warning_area' and r.geom is not null and public.ST_Intersects(a.geom, r.geom)),
  'danger', (select coalesce(jsonb_agg(distinct z.attrs->>'reason'), '[]') from geo.area z, r where z.kind = 'flood_zone' and r.geom is not null and public.ST_DWithin(z.geom, r.geom, 0.03)),
  'sources', (select coalesce(jsonb_agg(distinct jsonb_build_object('slug', s.slug, 'name', s.name, 'evidence', s.evidence_class, 'licence', s.licence, 'ds', to_jsonb(s.datasets))), '[]')
              from ref.source s where s.slug in ('os_open_rivers','ea_cde_classification','castco_wfd_c4','castco_separate','ea_edm_annual','nsoh_england','ea_bathing','castco_big_river_watch','castco_riverfly',
                                                 'ea_hydrology','ea_flood_monitoring','nrfa','openalex','nrw_datamap_wfs','ea_cde_rnag','ea_wq_archive','ffc_fgs','ea_flood_zones'))
) where exists (select 1 from r);
$$;

grant usage on schema api to anon, authenticated, service_role;
grant execute on all functions in schema api to anon, authenticated, service_role;
