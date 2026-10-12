-- core.gauge_flow_now is refilled by scripts/load/derive_extras.sql; declared here so the api views below exist on a fresh database.
create table if not exists core.gauge_flow_now (
  site_id bigint primary key references core.site(id), series_id bigint, value double precision, observed_at timestamptz,
  nrfa_series_id bigint, pct_of_record real, n_record bigint);
create index if not exists gauge_flow_now_series on core.gauge_flow_now (series_id);
create index if not exists gauge_flow_now_nrfa on core.gauge_flow_now (nrfa_series_id);
-- Public read surface. Views run as owner (they read private schemas); nothing writable is exposed.

create view api.sources as
select s.slug, s.name, s.publisher, s.country, s.kind, s.evidence_class::text as evidence_class, s.status, s.status_note, s.cadence,
       l.slug as licence, l.name as licence_name, l.allows_redistribution, l.allows_commercial
from ingest.source s left join ingest.licence l on l.id = s.licence_id;

create view api.waterbodies as
select w.id, w.wb_code, w.name, w.category, w.country, w.length_km, w.area_km2,
       (select jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class::text, 'basis', s.basis))
        from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = w.id) as signals
from core.waterbody w where w.line_geom is not null;

create view api.rivers as
select r.id, r.slug, r.name, r.name_cy, round(r.length_km::numeric, 1) as length_km, r.strahler_max, p.slug as parent_slug, p.name as parent_name,
       (select jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'evidence', s.evidence_class::text))
        from core.signal s where s.entity_kind = 'river' and s.entity_id = r.id) as signals
from core.river r left join core.river p on p.id = r.parent_river_id
where r.length_km >= 5;

create view api.overflows_now as
select s.id as site_id, s.name, o.receiving_water_raw as receiving_water, org.name as company, st.status, st.raw_status, st.status_since, st.last_event_start, st.last_event_end, st.reported_at, st.fetched_at,
       public.ST_Y(s.geom) as lat, public.ST_X(s.geom) as lon, r.slug as river_slug, r.name as river_name, w.name as waterbody_name,
       a.spill_count as spills_2025, a.total_duration_hr as hours_2025
from core.overflow_status st
join core.site s on s.id = st.site_id and s.merged_into is null
join core.overflow o on o.site_id = s.id
left join ref.organisation org on org.id = o.company_id
left join core.river r on r.id = s.river_id
left join core.waterbody w on w.id = s.waterbody_id
left join core.discharge_annual a on a.site_id = s.id and a.year = 2025
where st.status in ('discharging','offline') or st.last_event_end > now() - interval '24 hours';

create view api.bathing_now as
select s.id as site_id, s.name, s.attrs->>'water_type' as water_type, public.ST_Y(s.geom) as lat, public.ST_X(s.geom) as lon,
       ba.classification, ba.year as classification_year, ba.rank,
       ec.observed_at as last_sample_at, ec.value as ecoli, ec.censor as ecoli_censor, r.slug as river_slug
from core.site s
left join lateral (select * from core.bathing_assessment b where b.site_id = s.id order by year desc limit 1) ba on true
left join lateral (select o.observed_at, o.value, o.censor from core.series se join core.observation o on o.series_id = se.id
                   where se.site_id = s.id and se.source_series_key like 'bwq:%:ecoli' order by o.observed_at desc limit 1) ec on true
left join core.river r on r.id = s.river_id
where s.kind = 'bathing_water' and s.merged_into is null;

create view api.gauges_now as
select s.id as site_id, s.name, public.ST_Y(s.geom) as lat, public.ST_X(s.geom) as lon, g.value as flow_m3s, g.observed_at, round((g.pct_of_record * 100)::numeric) as pct_of_record,
       g.n_record, r.slug as river_slug, r.name as river_name
from core.gauge_flow_now g join core.site s on s.id = g.site_id left join core.river r on r.id = s.river_id;

create view api.flood_warnings_now as
select a.code, a.name, w.severity_level, w.message, w.raised_at, w.changed_at, w.fetched_at
from core.flood_warning w join core.flood_area a on a.id = w.area_id where w.severity_level < 4;

create function api.search_rivers(q text) returns table (slug text, name text, name_cy text, length_km numeric, parent_name text)
language sql stable security definer set search_path = '' as $$
  select r.slug, r.name, r.name_cy, round(r.length_km::numeric, 1), p.name
  from core.river r left join core.river p on p.id = r.parent_river_id
  where r.length_km >= 5 and (r.name ilike '%' || q || '%' or r.name_cy ilike '%' || q || '%')
  order by (r.name ilike q || '%' or r.name_cy ilike q || '%') desc, r.length_km desc limit 12;
$$;

-- Everything about one river, with the evidence class and source of each block. Catchment scope = the river plus all its tributaries.
create function api.river_dossier(p_slug text) returns jsonb
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
  'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'rank', s.state_rank, 'trend', s.trend, 'evidence', s.evidence_class::text, 'basis', s.basis)), '{}')
              from core.signal s, r where s.entity_kind = 'river' and s.entity_id = r.id),
  'waterbodies', (select coalesce(jsonb_agg(jsonb_build_object('id', w.id, 'code', w.wb_code, 'name', w.name, 'country', w.country, 'km', round((wbs.len / 1000)::numeric, 1),
        'classes', (select coalesce(jsonb_object_agg(c.element_code, c.status || ' ' || c.year), '{}') from (
                      select distinct on (element_code) element_code, status, year from core.waterbody_classification
                      where waterbody_id = w.id and element_code in ('overall','ecological','chemical','phosphate','ammonia','dissolved_oxygen','fish','invertebrates','sac_phosphorus')
                      order by element_code, cycle desc, year desc) c),
        'signals', (select coalesce(jsonb_object_agg(s.signal_code, jsonb_build_object('state', s.state, 'trend', s.trend)), '{}') from core.signal s where s.entity_kind = 'waterbody' and s.entity_id = w.id),
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
  'gauges', (select coalesce(jsonb_agg(jsonb_build_object('name', g.name, 'flow_m3s', round(g.flow_m3s::numeric, 3), 'observed_at', g.observed_at, 'pct_of_record', g.pct_of_record) order by g.n_record desc nulls last), '[]')
             from (select * from api.gauges_now where river_slug = p_slug order by n_record desc nulls last limit 4) g),
  'citizen', (select jsonb_build_object(
        'big_river_watch_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months'),
        'unhealthy_36m', count(*) filter (where kind = 'big_river_watch' and surveyed_at > now() - interval '36 months' and answers->>'health' = 'Unhealthy'),
        'riverfly_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months'),
        'riverfly_breaches_24m', count(*) filter (where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' and breach))
      from core.survey where waterbody_id in (select waterbody_id from wbs)),
  'research', (select coalesce(jsonb_agg(jsonb_build_object('title', w.title, 'year', w.pub_year, 'venue', w.venue, 'authors', (select jsonb_agg(a->>'name') from (select a from jsonb_array_elements(w.authors) a limit 3) z),
        'url', coalesce(w.landing_url, 'https://doi.org/' || w.doi), 'oa', w.oa_status, 'licence', w.licence, 'reviewed', wp.status = 'accepted', 'confidence', wp.confidence) order by wp.confidence desc, w.cited_by desc nulls last), '[]')
      from (select wp.* from research.work_place wp, r where wp.place_kind = 'river' and wp.place_id = r.id and wp.status <> 'rejected' order by confidence desc limit 8) wp join research.work w on w.id = wp.work_id),
  'sources', (select coalesce(jsonb_agg(distinct jsonb_build_object('slug', s.slug, 'name', s.name, 'evidence', s.evidence_class::text, 'licence', l.slug)), '[]')
              from ingest.source s left join ingest.licence l on l.id = s.licence_id where s.slug in ('os_open_rivers','ea_cde_classification','castco_wfd_c4','castco_separate','ea_edm_annual','nsoh_england','ea_bathing','castco_big_river_watch','castco_riverfly','ea_hydrology','ea_flood_monitoring','nrfa','openalex','nrw_datamap_wfs','ea_cde_rnag'))
) where exists (select 1 from r);
$$;

grant select on all tables in schema api to anon, authenticated;
grant execute on all functions in schema api to anon, authenticated;
