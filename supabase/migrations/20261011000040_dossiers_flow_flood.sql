-- dossiers: flow state, five-day outlook, active warnings and danger zones touching a stretch or river.
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
  'flow', (select s.basis || jsonb_build_object('summary', s.summary, 'state', s.state, 'rank', s.state_rank) from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = p_id and s.signal_code = 'flow'),
  'outlook', (select jsonb_build_object('area', b.name, 'days', (select string_agg(f.risk, ',' order by f.day) from core.flood_forecast f where f.area_id = b.id and f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1)))
              from core.boundary b, w where b.kind = 'flood_area' and w.line_geom is not null and ST_Intersects(b.geom, ST_PointOnSurface(w.line_geom)) limit 1),
  'warnings', (select coalesce(jsonb_agg(jsonb_build_object('name', a.name, 'sv', x.severity_level, 'message', left(x.message, 300))), '[]') from core.flood_area a, w
               join lateral (select 1) z on true
               cross join lateral (select * from core.flood_warning fw where fw.area_id = a.id order by fw.changed_at desc nulls last limit 1) x
               where a.geom_active is not null and w.line_geom is not null and x.severity_level < 4 and ST_Intersects(a.geom_active, w.line_geom)),
  'danger', (select coalesce(jsonb_agg(distinct z.reason), '[]') from core.flood_zone z, w where w.line_geom is not null and ST_DWithin(z.geom, w.line_geom, 0.03)),
  'river_signals', (select coalesce(jsonb_object_agg(s.signal_code, s.state_rank), '{}') from core.signal s join rv on s.entity_kind = 'river' and s.entity_id = rv.id)
) where exists (select 1 from w);
$$;

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
  'sources', (select coalesce(jsonb_agg(distinct jsonb_build_object('slug', s.slug, 'name', s.name, 'evidence', s.evidence_class::text, 'licence', l.slug)), '[]')
              from ingest.source s left join ingest.licence l on l.id = s.licence_id where s.slug in ('os_open_rivers','ea_cde_classification','castco_wfd_c4','castco_separate','ea_edm_annual','nsoh_england','ea_bathing','castco_big_river_watch','castco_riverfly','ea_hydrology','ea_flood_monitoring','nrfa','openalex','nrw_datamap_wfs','ea_cde_rnag'))
) where exists (select 1 from r);
$$;

grant execute on function api.stretch_dossier(bigint), api.river_dossier(text) to anon, authenticated;
