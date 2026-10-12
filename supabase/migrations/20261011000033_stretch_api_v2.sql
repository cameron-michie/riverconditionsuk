-- v2: readings fall back to nearest monitoring (<= 5 km, labelled); gauges/bathing are those on the stretch; overflows report both on-stretch and catchment counts.
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
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('name', s.name, 'q', round(g.value::numeric, 3), 'p', round((g.pct_of_record * 100)::numeric), 'at', g.observed_at)), '[]') from core.gauge_flow_now g join core.site s on s.id = g.site_id where s.id in (select id from sites)),
  'bathing', (select coalesce(jsonb_agg(jsonb_build_object('name', b.name, 'class', b.classification, 'year', b.classification_year, 'ecoli', b.ecoli, 'censor', b.ecoli_censor)), '[]') from api.bathing_now b where b.site_id in (select id from sites)),
  'citizen', (select jsonb_build_object('brw_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
                  'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
                  'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
                  'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach)) from core.survey where waterbody_id = p_id),
  'river_signals', (select coalesce(jsonb_object_agg(s.signal_code, s.state_rank), '{}') from core.signal s join rv on s.entity_kind = 'river' and s.entity_id = rv.id)
) where exists (select 1 from w);
$$;
grant execute on function api.stretch_dossier(bigint) to anon, authenticated;
