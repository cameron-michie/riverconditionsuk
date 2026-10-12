-- 'beach' || 's' is 'beachs'. Map POI kinds to layer codes explicitly.
create or replace view core.map_point as
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
select case p.kind when 'beach' then 'beaches' when 'bridge' then 'bridges' when 'reservoir' then 'reservoirs' end, p.id, p.geom, false,
       jsonb_build_object('n', p.name, 'rv', r.slug, 'rn', r.name, 'wb', w.name)
from core.poi p left join core.river r on r.id = p.river_id left join core.waterbody w on w.id = p.waterbody_id
where p.kind in ('bridge','reservoir') or (p.kind = 'beach' and p.bathing_site_id is null);
