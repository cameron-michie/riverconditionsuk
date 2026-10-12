-- v8: gauges carry height, flow and a flood index; sewage works; flood outlook and warnings; massive bridges as outlines.
-- Every point layer in one shape: (layer, id, geom, hot, props). `hot` = worth showing when zoomed out.
create or replace view core.map_point as
select 'overflows'::text as layer, s.id, s.geom, (st.status = 'discharging') as hot,
       jsonb_build_object('n', s.name, 'co', org.name, 'st', coalesce(st.status, 'unknown'), 'since', st.status_since, 'rw', o.receiving_water_raw,
                          'rv', r.slug, 'rn', r.name, 'sp', a.spill_count, 'hr', round(a.total_duration_hr::numeric), 'rep', st.reported_at, 'ls', st.last_event_start, 'le', st.last_event_end,
                          'mon', coalesce(st.status in ('discharging','not_discharging'), false)) as props
from core.site s join core.overflow o on o.site_id = s.id
left join core.overflow_status st on st.site_id = s.id left join ref.organisation org on org.id = o.company_id
left join core.river r on r.id = s.river_id left join core.discharge_annual a on a.site_id = s.id and a.year = 2025
where s.kind = 'storm_overflow' and s.merged_into is null
union all
select 'bathing', s.id, s.geom, coalesce(ba.classification = 'poor', false),
       jsonb_build_object('n', s.name, 'wt', s.attrs->>'water_type', 'cl', ba.classification, 'cy', ba.year, 'at', ec.observed_at, 'ec', ec.value, 'cn', ec.censor, 'rv', r.slug, 'rn', r.name)
from core.site s
left join lateral (select classification, year from core.bathing_assessment b where b.site_id = s.id order by year desc limit 1) ba on true
left join lateral (select o.observed_at, o.value, o.censor from core.series se join core.observation o on o.series_id = se.id where se.site_id = s.id and se.source_series_key like 'bwq:%:ecoli' order by o.observed_at desc limit 1) ec on true
left join core.river r on r.id = s.river_id
where s.kind = 'bathing_water' and s.merged_into is null
union all
select 'gauges', s.id, s.geom, (g.band_rank >= 3),
       jsonb_build_object('n', s.name, 'b', g.band_rank, 'bd', g.band, 'lv', round(g.stage::numeric, 2), 'th', g.typical_high, 'ix', round(g.level_index::numeric, 2), 'q', round(g.flow::numeric, 3), 'qi', round(g.flow_index::numeric, 2),
                          'p', round(g.flow_pct::numeric), 'at', greatest(g.stage_at, g.flow_at), 'rv', r.slug, 'rn', r.name)
from core.gauge_state g join core.site s on s.id = g.site_id left join core.river r on r.id = s.river_id
union all
select 'bridges', p.id, p.geom, false, jsonb_build_object('n', p.name, 'rv', r.slug, 'rn', r.name, 'wb', w.name)
from core.poi p left join core.river r on r.id = p.river_id left join core.waterbody w on w.id = p.waterbody_id where p.kind = 'bridge'
union all
select 'sewage_works', w.id, w.geom, false,
       jsonb_strip_nulls(jsonb_build_object('n', w.name, 'co', org.name, 'rw', w.receiving_water_raw, 'm', w.measured, 'pm', w.permit_ref, 'rv', r.slug, 'rn', r.name,
                          'at', w.attrs->>'latest_at', 'nh', w.attrs->'latest'->'ammonia_total_n'->>'v', 'nhc', w.attrs->'latest'->'ammonia_total_n'->>'c', 'bod', w.attrs->'latest'->'bod5'->>'v', 'ss', w.attrs->'latest'->'suspended_solids'->>'v', 'tp', w.attrs->'latest'->'phosphorus_total'->>'v'))
from core.sewage_works w left join ref.organisation org on org.id = w.company_id left join core.river r on r.id = w.river_id;

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
                 'properties', jsonb_strip_nulls(jsonb_build_object('o', l.size_class, 'r', r.slug, 'w', ms.waterbody_id, 'n', coalesce(ms.name, r.name), 's', ms.s, 't', ms.t, 'k', ms.km)),
                 'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(l.geom, $1), $2)::jsonb) f
        from core.river_link l left join core.river r on r.id = l.river_id left join core.waterbody_map_state ms on ms.waterbody_id = l.waterbody_id
        where l.river_class >= %s and l.geom && $3 order by l.river_class desc, l.size_class desc limit $4) q $q$, ord)
      into feats, n using tol, dg, box, lay.max_features;
    capped := n >= lay.max_features;

  elsif p_layer = 'river_labels' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_build_object('n', q.name, 'km', q.km),'geometry',ST_AsGeoJSON(q.label_pt, dg)::jsonb)), '[]'), count(*) into feats, n
    from (select r.name, round(r.length_km::numeric) km, r.label_pt from core.river r
          where r.label_pt && box
            and r.river_class >= coalesce((select q.threshold from core.map_zoom_rule q where q.layer = 'network' and q.from_zoom <= z order by q.from_zoom desc limit 1), 0)   -- only rivers that are drawn at this zoom
            and r.length_km >= coalesce((select q.threshold from core.map_zoom_rule q where q.layer = 'river_labels' and q.from_zoom <= z order by q.from_zoom desc limit 1), 0)
          order by r.length_km desc limit lay.max_features) q;

  elsif p_layer = 'water' then
    -- natural water drawn at true size (like the towns), thinned by area as you zoom out
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_strip_nulls(jsonb_build_object('n', q.name, 'k', q.kind, 'a', round(q.area_km2::numeric, 3), 'lx', ST_X(q.label_pt), 'ly', ST_Y(q.label_pt))),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(q.geom, tol), dg)::jsonb)), '[]'), count(*) into feats, n
    from (select w.name, w.kind, w.area_km2, w.label_pt, w.geom from core.water_area w
          where w.geom && box and w.area_km2 >= coalesce((select z2.threshold from core.map_zoom_rule z2 where z2.layer = 'water' and z2.from_zoom <= z order by z2.from_zoom desc limit 1), 0)
          order by w.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'beaches' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties',jsonb_strip_nulls(jsonb_build_object('n', q.name, 'a', round(q.area_km2::numeric, 4), 'lx', ST_X(q.label_pt), 'ly', ST_Y(q.label_pt))),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(q.geom, tol * 0.5), dg)::jsonb)), '[]'), count(*) into feats, n
    from (select b.name, b.area_km2, b.label_pt, b.geom from core.beach_area b where b.geom && box order by b.area_km2 desc limit lay.max_features) q;
    capped := n >= lay.max_features;

  elsif p_layer = 'flood_outlook' then
    -- Flood Forecasting Centre five-day outlook: r = worst risk over the five days (0 very low .. 3 high), d = the five daily codes
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('n', q.name, 'r', q.r, 'd', q.d, 'lx', ST_X(q.label_pt), 'ly', ST_Y(q.label_pt)),
             'geometry', ST_AsGeoJSON(case when z <= 6 then q.geom_lo when z <= 9 then q.geom_mid else ST_SimplifyPreserveTopology(q.geom, tol) end, dg)::jsonb)), '[]') into feats
    from (select b.name, b.label_pt, b.geom, b.geom_lo, b.geom_mid,
                 (select max(array_position(array['VL','L','M','H'], f.risk)) - 1 from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)) r,
                 (select string_agg(f.risk, ',' order by f.day) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)) d
          from core.boundary b where b.kind = 'flood_area' and b.geom && box) q;

  elsif p_layer = 'flood_warnings' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('n', q.name, 'sv', q.sv, 'm', left(q.message, 220)),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(q.geom_active, tol), dg)::jsonb)), '[]') into feats
    from (select a.name, a.geom_active, w.severity_level sv, w.message from core.flood_area a
          join lateral (select * from core.flood_warning w where w.area_id = a.id order by w.changed_at desc nulls last limit 1) w on w.severity_level < 4
          where a.geom_active && box) q;

  elsif p_layer = 'bridge_areas' then
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('n', b.name, 'l', b.length_m),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(b.geom, tol * 0.3), 6)::jsonb)), '[]') into feats from core.bridge_area b where b.geom && box;

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


create or replace function api.area_summary(p_minx double precision, p_miny double precision, p_maxx double precision, p_maxy double precision) returns jsonb
language plpgsql stable security definer set search_path = core, ref, public, pg_temp as $$
declare env geometry := ST_MakeEnvelope(p_minx, p_miny, p_maxx, p_maxy, 4326); r jsonb;
begin
  if (p_maxx - p_minx) > 4.5 or (p_maxy - p_miny) > 3.5 then
    return jsonb_build_object('too_wide', true);
  end if;
  select jsonb_build_object(
    'overflows', (select jsonb_build_object('n', count(*), 'discharging', count(*) filter (where props->>'st' = 'discharging'), 'offline', count(*) filter (where props->>'st' = 'offline'),
        'spills_2025', coalesce(sum((props->>'sp')::int), 0),
        'worst', (select coalesce(jsonb_agg(jsonb_build_object('n', w.props->>'n', 'co', w.props->>'co', 'sp', (w.props->>'sp')::int, 'hr', (w.props->>'hr')::int, 'st', w.props->>'st', 'x', ST_X(w.geom), 'y', ST_Y(w.geom))), '[]')
                  from (select * from core.map_point m2 where m2.layer = 'overflows' and m2.geom && env and m2.props->>'sp' is not null order by (m2.props->>'sp')::int desc limit 5) w))
      from core.map_point m where m.layer = 'overflows' and m.geom && env),
    'stretches', (select coalesce(jsonb_object_agg(z.code, z.arr), '{}') from (
        select d.code, jsonb_agg(c.cnt order by k) arr
        from core.signal_def d cross join generate_series(0, 4) k
        cross join lateral (select count(*) cnt from core.waterbody w join core.waterbody_map_state ms on ms.waterbody_id = w.id
                            where w.line_geom && env and substr(ms.s, d.sort::int, 1)::int = k) c
        group by d.code) z),
    'rivers', (select coalesce(jsonb_agg(jsonb_build_object('slug', q.slug, 'n', q.name, 'km', q.km, 's', q.s) order by q.km desc), '[]')
      from (select r.slug, r.name, round(r.length_km::numeric) km,
                   (select string_agg(coalesce(sg.state_rank::text, '0'), '' order by d.sort) from core.signal_def d left join core.signal sg on sg.entity_kind = 'river' and sg.entity_id = r.id and sg.signal_code = d.code) s
            from core.river r where r.geom && env and r.length_km >= 8 order by r.length_km desc limit 8) q),
    'bathing', (select coalesce(jsonb_agg(jsonb_build_object('n', props->>'n', 'cl', props->>'cl', 'ec', props->>'ec', 'cn', props->>'cn', 'x', ST_X(geom), 'y', ST_Y(geom))), '[]')
      from (select * from core.map_point where layer = 'bathing' and geom && env order by (props->>'n') limit 8) b),
    'gauges', (select jsonb_build_object('n', count(*), 'bands', (select coalesce(jsonb_object_agg(bd, c), '{}') from (select props->>'bd' bd, count(*) c from core.map_point where layer = 'gauges' and geom && env group by 1) z),
        'extreme', (select coalesce(jsonb_agg(jsonb_build_object('n', e.props->>'n', 'bd', e.props->>'bd', 'q', e.props->>'q', 'lv', e.props->>'lv', 'x', ST_X(e.geom), 'y', ST_Y(e.geom))), '[]')
                    from (select * from core.map_point g2 where g2.layer = 'gauges' and g2.geom && env order by (g2.props->>'b')::int desc, g2.id limit 4) e))
      from core.map_point g where g.layer = 'gauges' and g.geom && env),
    'works', (select jsonb_build_object('n', count(*), 'measured', count(*) filter (where (props->>'m')::boolean)) from core.map_point where layer = 'sewage_works' and geom && env),
    'outlook', (select coalesce(jsonb_agg(jsonb_build_object('n', q.name, 'd', q.d) order by q.r desc, q.name), '[]') from (
        select b.name, (select max(array_position(array['VL','L','M','H'], f.risk)) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)) r,
               (select string_agg(f.risk, ',' order by f.day) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)) d
        from core.boundary b where b.kind = 'flood_area' and b.geom && env) q),
    'warnings', (select coalesce(jsonb_agg(jsonb_build_object('n', a.name, 'sv', w.severity_level)), '[]') from core.flood_area a join lateral (select * from core.flood_warning w where w.area_id = a.id order by w.changed_at desc nulls last limit 1) w on w.severity_level < 4 where a.geom_active && env),
    'counts', (select coalesce(jsonb_object_agg(layer, n), '{}') from (select layer, count(*) n from core.map_point where layer in ('bridges','reservoirs','beaches') and geom && env group by 1) z),
    'parks', (select coalesce(jsonb_agg(name), '[]') from core.boundary where kind = 'national_park' and geom && env),
    'towns', (select coalesce(jsonb_agg(name order by area_km2 desc), '[]') from (select name, area_km2 from core.boundary where kind = 'urban_area' and label_pt && env order by area_km2 desc limit 6) t)
  ) into r;
  perform set_config('response.headers', '[{"Cache-Control":"public, max-age=30"}]', true);
  return r;
end $$;
create or replace function api.stretch_dossier(p_id bigint) returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
with w as (select * from core.waterbody where id = p_id),
rv as (select r.id, r.slug, r.name, r.length_km from core.waterbody_river wr join core.river r on r.id = wr.river_id where wr.waterbody_id = p_id),
sites as (select s.id from core.site s join core.river_link l on l.id = s.river_link_id where l.waterbody_id = p_id and s.merged_into is null),
latest as (
  select distinct on (p.code) p.code, p.name pname, st.name site_name, l.observed_at, l.value, l.censor, u.symbol
  from core.site st join core.series s on s.site_id = st.id and s.status = 'active' join ref.parameter p on p.id = s.parameter_id
  join core.observation_latest l on l.series_id = s.id join ref.unit u on u.id = s.unit_id
  where st.id in (select id from sites) and p.code in ('phosphorus_reactive','phosphorus_total','ammonia_total_n','nitrate_n','dissolved_oxygen_sat','dissolved_oxygen_conc','water_temperature','ph','turbidity','conductivity','bod5')
    and (l.value is not null or l.censor is not null)
  order by p.code, l.observed_at desc),
near as (
  select distinct on (p.code) p.code, p.name pname, st.name site_name, l.observed_at, l.value, l.censor, u.symbol,
         round((ST_Distance(st.geom::geography, w.line_geom::geography) / 1000)::numeric, 1) dist_km
  from w, core.site st join core.series s on s.site_id = st.id and s.status = 'active' join ref.parameter p on p.id = s.parameter_id
  join core.observation_latest l on l.series_id = s.id join ref.unit u on u.id = s.unit_id
  where w.line_geom is not null and ST_DWithin(st.geom, w.line_geom, 0.05) and st.merged_into is null and st.id not in (select id from sites)
    and ST_Distance(st.geom::geography, w.line_geom::geography) <= 5000
    and p.code in ('phosphorus_reactive','phosphorus_total','ammonia_total_n','nitrate_n','dissolved_oxygen_sat','dissolved_oxygen_conc','water_temperature','ph','turbidity','conductivity','bod5')
    and (l.value is not null or l.censor is not null)
  order by p.code, l.observed_at desc),
cls as (
  select e.code, e.label, cur.status, cur.year, cur.cycle, cur.certainty, prev.status prev_status, e.level
  from ref.classification_element e
  cross join lateral (select status, year, cycle, certainty from core.waterbody_classification c where c.waterbody_id = p_id and c.element_code = e.code order by cycle desc, year desc limit 1) cur
  left join lateral (select status from core.waterbody_classification c where c.waterbody_id = p_id and c.element_code = e.code and c.cycle < cur.cycle order by cycle desc, year desc limit 1) prev on true
  where e.code in ('overall','ecological','chemical','phosphate','ammonia','dissolved_oxygen','ph','temperature','fish','invertebrates','macrophytes_phytobenthos','sac_phosphorus')),
ov as (
  select s.id, s.name, org.name company, st.status, a.spill_count, a.total_duration_hr
  from core.site s join core.overflow o on o.site_id = s.id left join core.overflow_status st on st.site_id = s.id
  left join ref.organisation org on org.id = o.company_id left join core.discharge_annual a on a.site_id = s.id and a.year = 2025
  where s.waterbody_id = p_id and s.kind = 'storm_overflow' and s.merged_into is null),
ov_on as (select * from ov where id in (select id from sites))
select jsonb_build_object(
  'stretch', (select jsonb_build_object('id', w.id, 'code', w.wb_code, 'name', w.name, 'category', w.category, 'country', w.country, 'km', round(w.length_km::numeric, 1), 'area_km2', round(w.area_km2::numeric),
                'designation', w.designation, 'upstream_km', (select round(max(upstream_km)::numeric) from core.river_link where waterbody_id = p_id),
                'catchment', (select c.name from core.catchment c where c.id = w.opcat_id), 'river', (select jsonb_build_object('slug', rv.slug, 'name', rv.name, 'km', round(rv.length_km::numeric)) from rv limit 1)) from w),
  'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class::text, 'summary', s.summary)), '{}')
              from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = p_id),
  'readings', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', pname, 'site', site_name, 'at', observed_at, 'v', value, 'c', censor, 'u', symbol) order by code), '[]') from latest),
  'readings_near', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', pname, 'site', site_name, 'at', observed_at, 'v', value, 'c', censor, 'u', symbol, 'km', dist_km) order by code), '[]') from near),
  'classes', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label, 'status', status, 'year', year, 'cycle', cycle, 'prev', prev_status, 'certainty', certainty) order by case code when 'overall' then 0 when 'ecological' then 1 when 'chemical' then 2 else 3 end, code), '[]') from cls),
  'reasons', (select coalesce(jsonb_agg(x), '[]') from (select distinct jsonb_build_object('sector', coalesce(r.sector_native, r.sector_code), 'activity', r.activity, 'element', e.label, 'certainty', r.certainty) x
                from core.waterbody_reason r left join ref.classification_element e on e.code = r.element_code where r.waterbody_id = p_id limit 12) q),
  'apportionment', (select coalesce(jsonb_agg(jsonb_build_object('pollutant', pollutant, 'sector', sector, 'share', share_pct, 'load_t_yr', load_t_yr) order by pollutant, share_pct desc nulls last), '[]') from core.waterbody_apportionment where waterbody_id = p_id and share_pct >= 1),
  'overflows', (select jsonb_build_object('n', count(*), 'on_stretch', (select count(*) from ov_on), 'discharging', count(*) filter (where status = 'discharging'), 'offline', count(*) filter (where status = 'offline'), 'spills_2025', coalesce(sum(spill_count), 0), 'hours_2025', round(coalesce(sum(total_duration_hr), 0)::numeric),
                  'worst', (select coalesce(jsonb_agg(jsonb_build_object('name', o2.name, 'company', o2.company, 'spills', o2.spill_count, 'hours', round(o2.total_duration_hr::numeric), 'status', o2.status)), '[]') from (select * from ov where spill_count is not null order by spill_count desc limit 5) o2)) from ov),
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'band', g.band, 'stage', round(g.stage::numeric, 2), 'typical_high', g.typical_high, 'level_index', round(g.level_index::numeric, 2), 'flow', round(g.flow::numeric, 3), 'flow_index', round(g.flow_index::numeric, 2), 'pct', round(g.flow_pct::numeric), 'at', greatest(g.stage_at, g.flow_at))), '[]')
              from core.gauge_state g join core.site s on s.id = g.site_id where s.id in (select id from sites)),
  'works', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'measured', w.measured)), '[]') from core.sewage_works w where w.waterbody_id = p_id),
  'bathing', (select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'class', b.classification, 'year', b.classification_year, 'ecoli', b.ecoli, 'censor', b.ecoli_censor)), '[]') from api.bathing_now b where b.site_id in (select id from sites)),
  'citizen', (select jsonb_build_object('brw_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
                  'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
                  'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
                  'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach)) from core.survey where waterbody_id = p_id),
  'river_signals', (select coalesce(jsonb_object_agg(s.signal_code, s.state_rank), '{}') from core.signal s join rv on s.entity_kind = 'river' and s.entity_id = rv.id)
) where exists (select 1 from w);
$$;

create or replace function api.ui_config() returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object(
    'layers',   (select jsonb_agg(jsonb_build_object('code', code, 'label', label, 'group', grp, 'kind', geom_kind, 'min_zoom', min_zoom, 'cluster_below', cluster_below, 'hot_only_below', hot_only_below, 'on', default_on, 'labels', has_labels, 'labels_on', labels_default) order by sort) from core.map_layer),
    'signals',  (select jsonb_agg(jsonb_build_object('code', code, 'label', short_label, 'words', words, 'pressure', is_pressure, 'about', description) order by sort) from core.signal_def),
    'evidence', (select jsonb_object_agg(code, jsonb_build_object('label', label, 'about', description)) from ref.evidence_class_def),
    'flood',    jsonb_build_object('bands', jsonb_build_array('low','normal','elevated','high','severe'),
                  'rules', (select jsonb_agg(jsonb_build_object('kind', kind, 'from', from_index, 'band', band, 'about', about) order by kind, from_index) from core.flood_index_rule),
                  'risk', jsonb_build_object('VL', 'very low', 'L', 'low', 'M', 'medium', 'H', 'high')));
$$;

create or replace function api.gauge_dossier(p_id bigint) returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
with s as (select * from core.site where id = p_id), g as (select * from core.gauge_state where site_id = p_id),
lvs as (select se.id from core.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'water_level' join core.observation_latest l on l.series_id = se.id
        where se.site_id = p_id and se.source_id = (select id from ingest.source where slug = 'ea_flood_monitoring') order by (se.qualifier ilike 'stage') desc, (se.datum = 'mASD') desc, l.observed_at desc limit 1),
fls as (select se.id from core.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'river_flow' join core.observation_latest l on l.series_id = se.id
        where se.site_id = p_id and se.source_id in (select id from ingest.source where slug in ('ea_flood_monitoring','ea_hydrology')) order by l.observed_at desc limit 1),
off as (select (select value from core.observation_latest where series_id = (select id from lvs)) - (select stage from g) o)
select jsonb_build_object(
  'site', (select jsonb_build_object('id', s.id, 'name', s.name, 'river', (select jsonb_build_object('slug', r.slug, 'name', r.name) from core.river r where r.id = s.river_id),
             'stretch', (select jsonb_build_object('id', w.id, 'name', w.name) from core.waterbody w where w.id = s.waterbody_id)) from s),
  'state', (select to_jsonb(g) - 'site_id' - 'updated_at' from g),
  'level', (select coalesce(jsonb_agg(jsonb_build_array(t, v) order by t), '[]') from (select distinct on (date_trunc('hour', o.observed_at)) extract(epoch from o.observed_at)::bigint t, round((o.value - coalesce((select o from off), 0))::numeric, 3) v
            from core.observation o where o.series_id = (select id from lvs) and o.observed_at > now() - interval '7 days' and o.value is not null order by date_trunc('hour', o.observed_at), o.observed_at desc) z),
  'flow', (select coalesce(jsonb_agg(jsonb_build_array(t, v) order by t), '[]') from (select distinct on (date_trunc('hour', o.observed_at)) extract(epoch from o.observed_at)::bigint t, round(o.value::numeric, 3) v
            from core.observation o where o.series_id = (select id from fls) and o.observed_at > now() - interval '7 days' and o.value is not null order by date_trunc('hour', o.observed_at), o.observed_at desc) z),
  'outlook', (select jsonb_build_object('area', b.name, 'days', (select string_agg(f.risk, ',' order by f.day) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)),
                'issued', (select max(issued_at) from core.flood_forecast)) from core.boundary b, s where b.kind = 'flood_area' and ST_Intersects(b.geom, s.geom) limit 1)
) where exists (select 1 from s);
$$;

create or replace function api.works_dossier(p_id bigint) returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
select jsonb_build_object(
  'works', jsonb_build_object('id', w.id, 'name', w.name, 'company', org.name, 'permit', w.permit_ref, 'receiving', w.receiving_water_raw, 'measured', w.measured, 'basis', w.attrs->>'basis', 'x', ST_X(w.geom), 'y', ST_Y(w.geom),
        'river', (select jsonb_build_object('slug', r.slug, 'name', r.name) from core.river r where r.id = w.river_id), 'stretch', (select jsonb_build_object('id', b.id, 'name', b.name) from core.waterbody b where b.id = w.waterbody_id)),
  'latest', (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'v', l.value, 'c', l.censor, 'u', u.symbol, 'at', l.observed_at) order by p.code), '[]')
             from core.series se join ref.parameter p on p.id = se.parameter_id join ref.unit u on u.id = se.unit_id join core.observation_latest l on l.series_id = se.id
             where se.site_id = w.monitor_site_id and se.matrix = 'effluent' and (l.value is not null or l.censor is not null)),
  'overflows_near', (select coalesce(jsonb_agg(jsonb_build_object('name', m.props->>'n', 'status', m.props->>'st', 'spills', (m.props->>'sp')::int) order by (m.props->>'sp')::int desc nulls last), '[]')
                     from core.map_point m where m.layer = 'overflows' and ST_DWithin(m.geom::geography, w.geom::geography, 500))
) from core.sewage_works w left join ref.organisation org on org.id = w.company_id where w.id = p_id;
$$;

grant execute on function api.ui_config(), api.gauge_dossier(bigint), api.works_dossier(bigint), api.stretch_dossier(bigint), api.area_summary(double precision, double precision, double precision, double precision), api.map_tile(text,int,int,int) to anon, authenticated;
