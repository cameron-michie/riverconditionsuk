-- Which readings does each source feed? The panel shows only the sources for the dataset being looked at.
alter table ingest.source add column datasets text[] not null default '{}';
update ingest.source set datasets = v.d from (values
  ('os_open_rivers', '{all}'::text[]), ('ea_cde_classification', '{chemical,ecology}'), ('castco_wfd_c4', '{chemical,ecology}'), ('nrw_datamap_wfs', '{chemical,ecology}'), ('ea_wq_archive', '{chemical,sewage}'), ('ea_bathing', '{chemical}'),
  ('castco_separate', '{sewage,farming}'), ('ea_cde_rnag', '{ecology,sewage,farming}'), ('ea_edm_annual', '{sewage}'), ('nsoh_england', '{sewage}'), ('castco_big_river_watch', '{algae}'), ('castco_riverfly', '{ecology}'),
  ('ea_hydrology', '{flow}'), ('ea_flood_monitoring', '{flow}'), ('nrfa', '{flow}'), ('ffc_fgs', '{flow}'), ('ea_flood_zones', '{flow}'), ('openalex', '{research}')) v(slug, d) where ingest.source.slug = v.slug;

create or replace function api.river_dossier(p_slug text) returns jsonb
language sql stable security definer set search_path = '' as $$
with r as (select * from core.river where slug = p_slug),
tree as (
  with recursive t as (select id, 0 d from r union all select c.id, t.d + 1 from core.river c join t on c.parent_river_id = t.id where t.d < 12)
  select id from t),
wbs as (
  select l.waterbody_id, sum(l.length_m) len from core.river_link l, r where l.river_id = r.id and l.waterbody_id is not null group by 1
  having sum(l.length_m) >= 300),
tot as (select sum(len) t from wbs),
ov as (
  select s.id, s.name, org.name company, st.status, a.spill_count, a.total_duration_hr, o.receiving_water_raw
  from core.site s join core.overflow o on o.site_id = s.id
  left join core.overflow_status st on st.site_id = s.id left join ref.organisation org on org.id = o.company_id
  left join core.discharge_annual a on a.site_id = s.id and a.year = 2025
  where s.kind = 'storm_overflow' and s.merged_into is null and s.river_id in (select id from tree)),
ap as (
  select a.pollutant, a.sector, round((sum(a.load_t_yr * 1)) ::numeric, 2) load_t, sum(a.load_t_yr) l
  from core.waterbody_apportionment a join wbs on wbs.waterbody_id = a.waterbody_id group by 1, 2),
ap_tot as (select pollutant, sum(l) tl from ap group by 1)
select jsonb_build_object(
  'river', (select jsonb_build_object('slug', r.slug, 'name', r.name, 'name_cy', r.name_cy, 'length_km', round(r.length_km::numeric, 1), 'strahler', r.strahler_max,
              'parent', (select jsonb_build_object('slug', p.slug, 'name', p.name) from core.river p where p.id = r.parent_river_id),
              'tributaries', (select count(*) - 1 from tree)) from r),
  'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class::text, 'summary', s.summary)), '{}')
              from core.signal s, r where s.entity_kind = 'river' and s.entity_id = r.id),
  'waterbodies', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'code', w.wb_code, 'name', w.name, 'country', w.country, 'km', round((wbs.len / 1000)::numeric, 1),
        'classes', (select coalesce(jsonb_object_agg(c.element_code, c.status || ' ' || c.year), '{}') from (
                      select distinct on (element_code) element_code, status, year from core.waterbody_classification
                      where waterbody_id = w.id and element_code in ('overall','ecological','chemical','phosphate','ammonia','dissolved_oxygen','fish','invertebrates','sac_phosphorus')
                      order by element_code, cycle desc, year desc) c),
        'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class::text, 'summary', s.summary)), '{}') from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = w.id),
        'reasons', (select coalesce(jsonb_object_agg(x.sector_code, x.n), '{}') from (select sector_code, count(*) n from core.waterbody_reason where waterbody_id = w.id and sector_code is not null group by 1) x)
      ) order by wbs.len desc), '[]') from wbs join core.waterbody w on w.id = wbs.waterbody_id),
  'apportionment', (select coalesce(jsonb_agg(jsonb_build_object('pollutant', ap.pollutant, 'sector', ap.sector, 'load_t_yr', ap.load_t, 'share_pct', round((100 * ap.l / nullif(ap_tot.tl, 0))::numeric, 1)) order by ap.pollutant, ap.l desc nulls last), '[]')
                    from ap join ap_tot using (pollutant)),
  'overflows', (select jsonb_build_object('count', count(*), 'discharging_now', count(*) filter (where status = 'discharging'), 'offline', count(*) filter (where status = 'offline'),
        'spills_2025', coalesce(sum(spill_count), 0), 'hours_2025', round(coalesce(sum(total_duration_hr), 0)::numeric),
        'worst', (select coalesce(jsonb_agg(jsonb_build_object('site_id', x.id, 'name', x.name, 'company', x.company, 'spills', x.spill_count, 'hours', round(x.total_duration_hr::numeric), 'status', x.status, 'receiving', x.receiving_water_raw)), '[]')
                  from (select * from ov where spill_count is not null order by spill_count desc limit 5) x)) from ov),
  'bathing', (select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'class', b.classification, 'year', b.classification_year, 'ecoli', b.ecoli, 'censor', b.ecoli_censor, 'sampled', b.last_sample_at)), '[]')
              from api.bathing_now b where b.river_slug = p_slug),
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'band', x.band, 'stage', round(x.stage::numeric, 2), 'flow', round(x.flow::numeric, 3), 'pct', round(x.flow_pct::numeric), 'at', greatest(x.stage_at, x.flow_at))), '[]')
             from (select s.id, s.name, g.* from core.gauge_state g join core.site s on s.id = g.site_id where s.river_id in (select id from tree) order by g.band_rank desc, s.name limit 5) x),
  'citizen', (select jsonb_build_object(
        'big_river_watch_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
        'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
        'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
        'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach))
      from core.survey where waterbody_id in (select waterbody_id from wbs)),
  'research', (select coalesce(jsonb_agg(jsonb_build_object('title', w.title, 'year', w.pub_year, 'venue', w.venue, 'authors', (select jsonb_agg(a->>'name') from (select a from jsonb_array_elements(w.authors) a limit 3) z),
        'url', coalesce(w.landing_url, 'https://doi.org/' || w.doi), 'oa', w.oa_status, 'licence', w.licence, 'reviewed', wp.status = 'accepted', 'confidence', wp.confidence) order by wp.confidence desc, w.cited_by desc nulls last), '[]')
      from (select wp.* from research.work_place wp, r where wp.place_kind = 'river' and wp.place_id = r.id and wp.status <> 'rejected' order by confidence desc limit 8) wp join research.work w on w.id = wp.work_id),
  'outlook', (select coalesce(jsonb_agg(jsonb_build_object('area', q.name, 'days', q.d) order by q.r desc, q.name), '[]') from (
               select b.name, (select max(array_position(array['VL','L','M','H'], f.risk)) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)) r,
                      (select string_agg(f.risk, ',' order by f.day) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)) d
               from core.boundary b, r where b.kind = 'flood_area' and r.geom is not null and public.ST_Intersects(b.geom_lo, r.geom) limit 3) q),
  'warnings', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'sv', x.severity_level, 'message', left(x.message, 300))), '[]') from core.flood_area a, r
               cross join lateral (select * from core.flood_warning fw where fw.area_id = a.id order by fw.changed_at desc nulls last limit 1) x
               where a.geom_active is not null and r.geom is not null and x.severity_level < 4 and public.ST_Intersects(a.geom_active, r.geom)),
  'danger', (select coalesce(jsonb_agg(distinct z.reason), '[]') from core.flood_zone z, r where r.geom is not null and public.ST_DWithin(z.geom, r.geom, 0.03)),
  'sources', (select coalesce(jsonb_agg(distinct jsonb_build_object('slug', s.slug, 'name', s.name, 'evidence', s.evidence_class::text, 'licence', l.slug, 'ds', to_jsonb(s.datasets))), '[]')
              from ingest.source s left join ingest.licence l on l.id = s.licence_id where s.slug in ('os_open_rivers','ea_cde_classification','castco_wfd_c4','castco_separate','ea_edm_annual','nsoh_england','ea_bathing','castco_big_river_watch','castco_riverfly','ea_hydrology','ea_flood_monitoring','nrfa','openalex','nrw_datamap_wfs','ea_cde_rnag','ea_wq_archive','ffc_fgs','ea_flood_zones'))
) where exists (select 1 from r);
$$;

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
        from core.signal_def d cross join generate_series(0, 5) k
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
grant execute on function api.river_dossier(text), api.area_summary(double precision, double precision, double precision, double precision) to anon, authenticated;
