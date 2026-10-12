-- Flow as a fifth reading: how high the flow is relative to normal for that river right now, and the expected flood plain where there is a flood risk.
insert into core.signal_def (code, label, description, short_label, words, sort, is_pressure)
values ('flow', 'Flow', 'River flow now against that river''s own long-term record, from the nearest gauge on the same river.', 'flow', '{much lower,lower,normal,higher,much higher}', 6, false);
alter table core.signal drop constraint signal_state_check;
alter table core.signal add constraint signal_state_check check (state in ('good','moderate','poor','bad','unknown','much_lower','lower','normal','higher','much_higher'));

create table core.flow_state_rule (from_pct numeric primary key, band text not null, rank smallint not null, label text not null);
insert into core.flow_state_rule values (0, 'much_lower', 1, 'much lower than normal'), (10, 'lower', 2, 'lower than normal'), (30, 'normal', 3, 'about normal'), (70, 'higher', 4, 'higher than normal'), (90, 'much_higher', 5, 'much higher than normal');
alter table core.flow_state_rule enable row level security; create policy public_read on core.flow_state_rule for select to anon, authenticated using (true);

create function core.ordinal(n integer) returns text language sql immutable as $$
  select n::text || case when n % 100 between 11 and 13 then 'th' else case n % 10 when 1 then 'st' when 2 then 'nd' when 3 then 'rd' else 'th' end end;
$$;

-- Each stretch takes the flow state of a gauge on it, else the nearest gauge on the same river within 60 km along the river. Rivers take the average of their stretches.
create or replace function core.refresh_flow_signals() returns void language plpgsql as $$
begin
  delete from core.signal where signal_code = 'flow';
  create temp table _wb on commit drop as
    select l.waterbody_id wid, (array_agg(l.river_id order by l.length_m desc))[1] river_id, avg(l.dist_to_mouth_m) ch from core.river_link l where l.waterbody_id is not null and l.river_id is not null group by l.waterbody_id;
  create temp table _g on commit drop as
    select s.id gid, s.name, s.river_id, s.waterbody_id, s.dist_to_mouth_m ch, g.flow, g.flow_pct, g.qmed from core.gauge_state g join core.site s on s.id = g.site_id
    where g.flow_pct is not null and g.flow_at > now() - interval '10 days' and s.river_id is not null;
  insert into core.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of, summary)
  select 'waterbody', w.wid, 'flow', r.band, r.rank, 'unknown',
         jsonb_build_object('gauge', g.gid, 'gauge_name', g.name, 'pct', round(g.flow_pct::numeric), 'flow', round(g.flow::numeric, 3), 'on_stretch', g.waterbody_id = w.wid, 'km_along_river', round((abs(g.ch - w.ch) / 1000)::numeric)),
         'official_monitoring', now(),
         'Flow at ' || g.name || case when g.waterbody_id = w.wid then '' else ' (' || round((abs(g.ch - w.ch) / 1000)::numeric) || ' km ' || case when g.ch > w.ch then 'upstream' else 'downstream' end || ' on the same river)' end
           || ' is ' || r.label || ': ' || core.ordinal(round(g.flow_pct::numeric)::int) || ' percentile of its record.'
  from _wb w
  join lateral (select * from _g g where g.river_id = w.river_id and (g.waterbody_id = w.wid or abs(g.ch - w.ch) <= 60000) order by (g.waterbody_id = w.wid) desc, abs(g.ch - w.ch) limit 1) g on true
  join lateral (select * from core.flow_state_rule r where r.from_pct <= g.flow_pct order by r.from_pct desc limit 1) r on true;
  insert into core.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of, summary)
  select 'river', x.river_id, 'flow', r.band, r.rank, 'unknown', jsonb_build_object('stretches', x.n), 'official_monitoring', now(),
         'Average over the ' || x.n || ' stretch' || case when x.n > 1 then 'es' else '' end || ' with a gauge: ' || r.label || '.'
  from (select w.river_id, count(*) n, round(avg(s.state_rank))::int rk from core.signal s join _wb w on w.wid = s.entity_id where s.entity_kind = 'waterbody' and s.signal_code = 'flow' group by w.river_id) x
  join core.flow_state_rule r on r.rank = x.rk;
  perform core.refresh_waterbody_map_state();
end $$;

-- Danger zones: flood zones 2 and 3 fetched only for places with an active flood risk (an alert or warning, or a gauge running high). Rebuilt by refresh_live.py.
create table core.flood_zone (
  id bigint generated always as identity primary key, zone text not null check (zone in ('FZ2','FZ3')), geom geometry(MultiPolygon,4326) not null,
  trigger text not null check (trigger in ('warning','gauge','outlook')), reason text not null, ref text, fetched_at timestamptz not null default now(), source_id bigint references ingest.source(id)
);
create index on core.flood_zone using gist (geom); create index on core.flood_zone (source_id);
alter table core.flood_zone enable row level security; create policy public_read on core.flood_zone for select to anon, authenticated using (true);
insert into core.map_layer (code, label, grp, geom_kind, min_zoom, default_on, sort, max_features, note)
  values ('flood_zones', 'danger zones', 'base', 'polygon', 6, true, 5, 3000, 'expected flood plain (EA flood zones 2 and 3) where there is an active flood risk');
insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, status_note)
  values ('ea_flood_zones', 'EA Flood Map for Planning: flood zones 2 and 3 (rivers and sea)', 'Environment Agency', 'ENG', 'ogc_features', 'https://environment.data.gov.uk/spatialdata/flood-map-for-planning-flood-zones/ogc/features/v1', (select id from ingest.licence where slug = 'ogl3'), 'regulator_assessment', 'P1D', null, 'active', 'England only; fetched by bounding box where a flood risk is active. Wales (NRW) not loaded.') on conflict (slug) do nothing;

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

  elsif p_layer = 'flood_zones' then
    -- the expected flood plain (EA flood zones 2 and 3), present only where a flood risk is active
    select coalesce(jsonb_agg(jsonb_build_object('type','Feature','properties', jsonb_build_object('z', q.zone, 'r', q.reason),
             'geometry', ST_AsGeoJSON(ST_SimplifyPreserveTopology(q.geom, tol * 0.6), dg)::jsonb) order by q.zone), '[]') into feats
    from (select f.zone, f.reason, f.geom from core.flood_zone f where f.geom && box limit lay.max_features) q;

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


grant execute on function api.map_tile(text,int,int,int) to anon, authenticated;
