-- Stretch = the regulator's waterbody, the unit the condition data actually describes. Hover and click operate on it, not on a single OS link.
alter table core.waterbody_map_state add column km real;
create or replace function core.refresh_waterbody_map_state() returns void language sql as $$
  truncate core.waterbody_map_state;
  insert into core.waterbody_map_state (waterbody_id, name, river_slug, s, t, km)
  select w.id, w.name, r.slug,
         (select string_agg(coalesce(sg.state_rank::text, '0'), '' order by d.sort) from core.signal_def d left join core.signal sg on sg.entity_kind = 'waterbody' and sg.entity_id = w.id and sg.signal_code = d.code),
         (select string_agg(case sg.trend when 'improving' then '+' when 'worsening' then '-' else '0' end, '' order by d.sort) from core.signal_def d left join core.signal sg on sg.entity_kind = 'waterbody' and sg.entity_id = w.id and sg.signal_code = d.code),
         w.length_km
  from core.waterbody w left join core.waterbody_river wr on wr.waterbody_id = w.id left join core.river r on r.id = wr.river_id;
$$;
select core.refresh_waterbody_map_state();

alter table ref.unit add column symbol text;
update ref.unit set symbol = v.sym from (values ('mg_l','mg/l'),('ug_l','µg/l'),('ng_l','ng/l'),('m3_s','m³/s'),('l_s','l/s'),('ml_d','Ml/d'),('m','m'),('cm','cm'),('mm','mm'),('celsius','°C'),('kelvin','K'),('pct','%'),('us_cm','µS/cm'),('ms_cm','mS/cm'),('ph','pH'),('ntu','NTU'),('per_100ml','/100 ml')) v(id, sym) where ref.unit.id = v.id;

create or replace function api.stretch_geom(p_id bigint) returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object('type','Feature','properties',jsonb_build_object('id', w.id, 'bbox', array[ST_XMin(w.line_geom), ST_YMin(w.line_geom), ST_XMax(w.line_geom), ST_YMax(w.line_geom)]),
         'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(w.line_geom, 0.0003), 5)::jsonb)
  from core.waterbody w where w.id = p_id and w.line_geom is not null;
$$;

create or replace function api.stretch_dossier(p_id bigint) returns jsonb language sql stable security definer set search_path = core, ref, public, pg_temp as $$
with w as (select * from core.waterbody where id = p_id),
rv as (select r.id, r.slug, r.name, r.length_km from core.waterbody_river wr join core.river r on r.id = wr.river_id where wr.waterbody_id = p_id),
sites as (select id from core.site where waterbody_id = p_id and merged_into is null),
latest as (
  select distinct on (p.code) p.code, p.name pname, st.name site_name, l.observed_at, l.value, l.censor, u.symbol
  from core.site st join core.series s on s.site_id = st.id and s.status = 'active' join ref.parameter p on p.id = s.parameter_id
  join core.observation_latest l on l.series_id = s.id join ref.unit u on u.id = s.unit_id
  where st.waterbody_id = p_id and st.merged_into is null and p.code in ('phosphorus_reactive','phosphorus_total','ammonia_total_n','nitrate_n','dissolved_oxygen_sat','dissolved_oxygen_conc','water_temperature','ph','turbidity','conductivity','bod5')
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
  where s.waterbody_id = p_id and s.kind = 'storm_overflow' and s.merged_into is null)
select jsonb_build_object(
  'stretch', (select jsonb_build_object('id', w.id, 'code', w.wb_code, 'name', w.name, 'category', w.category, 'country', w.country, 'km', round(w.length_km::numeric, 1), 'area_km2', round(w.area_km2::numeric),
                'designation', w.designation, 'upstream_km', (select round(max(upstream_km)::numeric) from core.river_link where waterbody_id = p_id),
                'catchment', (select c.name from core.catchment c where c.id = w.opcat_id), 'river', (select jsonb_build_object('slug', rv.slug, 'name', rv.name, 'km', round(rv.length_km::numeric)) from rv limit 1)) from w),
  'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class::text, 'summary', s.summary)), '{}')
              from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = p_id),
  'readings', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name', pname, 'site', site_name, 'at', observed_at, 'v', value, 'c', censor, 'u', symbol) order by code), '[]') from latest),
  'classes', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label, 'status', status, 'year', year, 'cycle', cycle, 'prev', prev_status, 'certainty', certainty) order by case code when 'overall' then 0 when 'ecological' then 1 when 'chemical' then 2 else 3 end, code), '[]') from cls),
  'reasons', (select coalesce(jsonb_agg(x), '[]') from (select distinct jsonb_build_object('sector', coalesce(r.sector_native, r.sector_code), 'activity', r.activity, 'element', e.label, 'certainty', r.certainty) x
                from core.waterbody_reason r left join ref.classification_element e on e.code = r.element_code where r.waterbody_id = p_id limit 12) q),
  'apportionment', (select coalesce(jsonb_agg(jsonb_build_object('pollutant', pollutant, 'sector', sector, 'share', share_pct, 'load_t_yr', load_t_yr) order by pollutant, share_pct desc nulls last), '[]') from core.waterbody_apportionment where waterbody_id = p_id and share_pct >= 1),
  'overflows', (select jsonb_build_object('n', count(*), 'discharging', count(*) filter (where status = 'discharging'), 'offline', count(*) filter (where status = 'offline'), 'spills_2025', coalesce(sum(spill_count), 0), 'hours_2025', round(coalesce(sum(total_duration_hr), 0)::numeric),
                  'worst', (select coalesce(jsonb_agg(jsonb_build_object('name', o2.name, 'company', o2.company, 'spills', o2.spill_count, 'hours', round(o2.total_duration_hr::numeric), 'status', o2.status)), '[]') from (select * from ov where spill_count is not null order by spill_count desc limit 5) o2)) from ov),
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'q', round(g.value::numeric, 3), 'p', round((g.pct_of_record * 100)::numeric), 'at', g.observed_at)), '[]') from core.gauge_flow_now g join core.site s on s.id = g.site_id where s.waterbody_id = p_id),
  'bathing', (select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'class', b.classification, 'year', b.classification_year, 'ecoli', b.ecoli, 'censor', b.ecoli_censor)), '[]') from api.bathing_now b where b.site_id in (select id from sites)),
  'citizen', (select jsonb_build_object('brw_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
                  'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
                  'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
                  'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach)) from core.survey where waterbody_id = p_id),
  'river_signals', (select coalesce(jsonb_object_agg(s.signal_code, s.state_rank), '{}') from core.signal s join rv on s.entity_kind = 'river' and s.entity_id = rv.id)
) where exists (select 1 from w);
$$;
grant execute on function api.stretch_geom(bigint), api.stretch_dossier(bigint) to anon, authenticated;

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

