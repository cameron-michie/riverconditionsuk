-- river dossier: gauges come from the flood state (height, flow, band), worst first.
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
  'sources', (select coalesce(jsonb_agg(distinct jsonb_build_object('slug', s.slug, 'name', s.name, 'evidence', s.evidence_class::text, 'licence', l.slug)), '[]')
              from ingest.source s left join ingest.licence l on l.id = s.licence_id where s.slug in ('os_open_rivers','ea_cde_classification','castco_wfd_c4','castco_separate','ea_edm_annual','nsoh_england','ea_bathing','castco_big_river_watch','castco_riverfly','ea_hydrology','ea_flood_monitoring','nrfa','openalex','nrw_datamap_wfs','ea_cde_rnag'))
) where exists (select 1 from r);
$$;

grant execute on function api.river_dossier(text) to anon, authenticated;
