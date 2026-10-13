-- v2 upgrade, step 3 of 3: copy and fold the data from the old schemas (core, ingest, wx, research, legacy_ref, legacy_ops, legacy_api)
-- into ref, geo, live and ops, repoint the satellite tables at the new geo tables, then drop the old objects.
-- Runs in the same transaction as v2_pre.sql and the baseline (scripts/migrate/v2_upgrade.sh).
-- Readings are copied in full: scripts/etl/archive.py then moves everything outside the 7-day window to the cold archive.

set local statement_timeout = 0;
set local work_mem = '256MB';

-- ─── ref ───
insert into ref.source (id, slug, name, publisher, country, kind, base_url, evidence_class, cadence, status, datasets,
                        licence, licence_name, licence_url, attribution, allows_redistribution, allows_commercial)
select s.id, s.slug, s.name, s.publisher, s.country, s.kind, s.base_url, s.evidence_class::text, s.cadence, coalesce(s.status, 'active'), s.datasets,
       l.slug, l.name, l.url, l.attribution_text, l.allows_redistribution, l.allows_commercial
from ingest.source s left join ingest.licence l on l.id = s.licence_id;

insert into ref.organisation (id, slug, name, kind, country, aliases)
select id, slug, name, kind, country, coalesce(aliases, '{}') from legacy_ref.organisation;

insert into ref.unit (id, label, symbol, dimension, is_canonical, factor, "offset", aliases)
select id, label, symbol, dimension, coalesce(is_canonical, false), factor, coalesce("offset", 0), coalesce(aliases, '{}') from legacy_ref.unit;

insert into ref.parameter (id, code, name, domain, canonical_unit, description, signal_code, higher_is, plausible_min, plausible_max)
select id, code, name, domain, canonical_unit, description, signal_code, higher_is, plausible_min, plausible_max from legacy_ref.parameter;

insert into ref.parameter_alias (id, source_id, native_code, native_label, native_unit, parameter_id, unit_id, fraction, method, matrix, status, confidence)
select id, source_id, native_code, native_label, native_unit, parameter_id, unit_id, fraction, method, matrix, coalesce(status, 'mapped'), confidence from legacy_ref.parameter_alias;

insert into ref.term (domain, code, label, about, sort, native, attrs)
select 'country', code, name, null::text, null::smallint, '{}'::text[], '{}'::jsonb from legacy_ref.country
union all
select 'evidence_class', code, label, description, sort, '{}', '{}' from legacy_ref.evidence_class_def
union all
select 'wfd_element', code, label, null, null, coalesce(native_names, '{}'), jsonb_strip_nulls(jsonb_build_object('level', level, 'signal_code', signal_code)) from legacy_ref.classification_element
union all
select 'pressure_sector', code, label, null, null, coalesce(native_names, '{}'), '{}' from legacy_ref.pressure_sector
union all
select domain, canonical, canonical, null, min(rank), array_agg(distinct native), '{}' from legacy_ref.value_map group by domain, canonical;

insert into ref.signal (code, label, short_label, description, words, sort, is_pressure)
select code, label, short_label, description, words, sort, coalesce(is_pressure, false) from core.signal_def;

insert into ref.band (kind, from_value, band, rank, label, about)
select kind, from_index, band, rank, null, about from core.flood_index_rule
union all
select 'flow_pct', from_pct, band, rank, label, null from core.flow_state_rule;

insert into ref.map_layer (code, label, grp, geom_kind, min_zoom, cluster_below, hot_only_below, default_on, has_labels, labels_default, sort, max_features, zoom_rules)
select l.code, l.label, l.grp, l.geom_kind, coalesce(l.min_zoom, 0), l.cluster_below, l.hot_only_below, coalesce(l.default_on, false), coalesce(l.has_labels, false), coalesce(l.labels_default, false),
       coalesce(l.sort, 0), coalesce(l.max_features, 4000),
       coalesce((select jsonb_agg(jsonb_build_array(z.from_zoom, z.threshold) order by z.from_zoom) from core.map_zoom_rule z where z.layer = l.code), '[]')
from core.map_layer l;

-- ─── geo: rivers, waterbodies, network ───
insert into geo.river (id, slug, name, name_cy, parent_river_id, mouth_node_id, source_node_id, length_km, strahler_max, river_class, aliases, research, geom, label_pt)
select r.id, r.slug, r.name, r.name_cy, r.parent_river_id, r.mouth_node_id, r.source_node_id, r.length_km, r.strahler_max, r.river_class,
       coalesce((select array_agg(a.alias order by a.alias) from core.river_alias a where a.river_id = r.id), '{}'),
       coalesce((select jsonb_agg(jsonb_build_object('title', w.title, 'year', w.pub_year, 'venue', w.venue,
                                                     'authors', (select jsonb_agg(a->>'name') from (select a from jsonb_array_elements(w.authors) a limit 3) z),
                                                     'url', coalesce(w.landing_url, 'https://doi.org/' || w.doi), 'oa', w.oa_status, 'licence', w.licence,
                                                     'reviewed', wp.status = 'accepted', 'confidence', wp.confidence) order by wp.confidence desc, w.cited_by desc nulls last)
                 from (select wp.* from research.work_place wp where wp.place_kind = 'river' and wp.place_id = r.id and wp.status <> 'rejected' order by confidence desc limit 8) wp
                 join research.work w on w.id = wp.work_id), '[]'),
       r.geom, r.label_pt
from core.river r;

create temp table _cls on commit drop as
  with per_cycle as (   -- the latest assessment within each cycle
    select distinct on (waterbody_id, element_code, cycle) waterbody_id, element_code, cycle, year, status, certainty
    from core.waterbody_classification order by waterbody_id, element_code, cycle, year desc),
  seq as (
    select *, lag(status) over (partition by waterbody_id, element_code order by cycle) prev,
           row_number() over (partition by waterbody_id, element_code order by cycle desc) rn
    from per_cycle)
  select waterbody_id, jsonb_object_agg(element_code, jsonb_strip_nulls(jsonb_build_object('status', status, 'year', year, 'cycle', cycle, 'certainty', certainty, 'prev', prev))) classes
  from seq where rn = 1 group by waterbody_id;
create index on _cls (waterbody_id);

create temp table _rsn on commit drop as
  select r.waterbody_id, jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sector', r.sector_code, 'sector_native', r.sector_native, 'activity', r.activity, 'element', r.element_code, 'certainty', r.certainty))
                                   order by r.sector_code, r.activity) reasons
  from core.waterbody_reason r
  where r.cycle is not distinct from (select max(r2.cycle) from core.waterbody_reason r2 where r2.waterbody_id = r.waterbody_id)
  group by r.waterbody_id;
create index on _rsn (waterbody_id);

insert into geo.waterbody (id, wb_code, name, category, designation, country, river_id, rbd, management_catchment, operational_catchment, area_km2, length_km, source_id,
                           ids, classes, reasons, apportionment, radar_cells, catchment_geom, line_geom)
select w.id, w.wb_code, w.name, w.category, w.designation, w.country,
       (select wr.river_id from core.waterbody_river wr where wr.waterbody_id = w.id),
       (select c.name from core.catchment c where c.id = w.rbd_id), (select c.name from core.catchment c where c.id = w.mancat_id), (select c.name from core.catchment c where c.id = w.opcat_id),
       w.area_km2, w.length_km, w.source_id,
       coalesce((select jsonb_object_agg(i.scheme, i.value) from core.waterbody_identifier i where i.waterbody_id = w.id), '{}'),
       coalesce((select classes from _cls where waterbody_id = w.id), '{}'),
       coalesce((select reasons from _rsn where waterbody_id = w.id), '[]'),
       coalesce((select jsonb_agg(jsonb_build_object('pollutant', a.pollutant, 'sector', a.sector, 'share_pct', a.share_pct, 'load_t_yr', a.load_t_yr) order by a.pollutant, a.share_pct desc nulls last)
                 from core.waterbody_apportionment a where a.waterbody_id = w.id), '[]'),
       (select array_agg(c.ix::int * 10000 + c.iy order by c.ix, c.iy) from wx.catchment_cell c where c.waterbody_id = w.id),
       w.catchment_geom, w.line_geom
from core.waterbody w;

insert into geo.river_link (id, os_id, river_id, waterbody_id, form, name, length_m, start_node_id, end_node_id, flow_direction, strahler, dist_to_mouth_m, upstream_km, size_class, river_class, geom, geom_bng)
select id, os_id, river_id, waterbody_id, form, name, length_m, start_node_id, end_node_id, flow_direction, strahler, dist_to_mouth_m, upstream_km, size_class, river_class, geom, geom_bng
from core.river_link;

-- ─── geo.area: every polygon ───
insert into geo.area (id, kind, code, name, name_alt, rank, area_km2, source_id, attrs, geom, geom_lo, geom_mid, label_pt)
select id, case kind when 'flood_area' then 'flood_outlook_area' else kind end, code, name, name_alt, rank, area_km2, source_id, coalesce(attrs, '{}'), geom, geom_lo, geom_mid, label_pt
from core.boundary;
select setval(pg_get_serial_sequence('geo.area', 'id'), (select max(id) from geo.area));
insert into geo.area (kind, code, name, area_km2, source_id, attrs, geom, label_pt)
select 'water', source_key, name, area_km2, source_id, coalesce(attrs, '{}') || jsonb_strip_nulls(jsonb_build_object('kind', kind, 'river_id', river_id)), geom, label_pt from core.water_area;
insert into geo.area (kind, code, name, area_km2, source_id, attrs, geom, label_pt)
select 'beach', source_key, name, area_km2, source_id, coalesce(attrs, '{}') || jsonb_strip_nulls(jsonb_build_object('bathing_site_id', bathing_site_id)), geom, label_pt from core.beach_area;
insert into geo.area (kind, code, name, source_id, attrs, geom)
select 'bridge', 'bridge:' || id, name, source_id, jsonb_strip_nulls(jsonb_build_object('length_m', length_m, 'source_keys', source_keys)), geom from core.bridge_area;
insert into geo.area (kind, code, name, source_id, attrs, geom)
select 'warning_area', code, name, source_id, jsonb_build_object('kind', kind), coalesce(geom_active, geom) from core.flood_area;
insert into geo.area (kind, code, source_id, attrs, geom)
select 'flood_zone', null, source_id, jsonb_strip_nulls(jsonb_build_object('zone', zone, 'trigger', trigger, 'reason', reason, 'ref', ref, 'fetched_at', fetched_at)), geom from core.flood_zone;

-- ─── geo.site: the sites anything still uses, with their side tables folded into attrs ───
create temp table _keep on commit drop as
  select s.id from core.site s
  where s.merged_into is null and (
        s.kind in ('storm_overflow', 'bathing_water', 'survey_site')
     or exists (select 1 from core.series se where se.site_id = s.id)
     or (s.kind = 'sewage_works' and s.attrs->>'permit_type' = 'WwTW/Sewage Treatment Works (water company)')
     or s.id in (select permit_site_id from core.sewage_works where permit_site_id is not null union select monitor_site_id from core.sewage_works where monitor_site_id is not null)
     or s.id in (select site_id from core.flow_normal union select site_id from core.flow_model_param union select site_id from core.site_stage_scale)
     or s.id in (select site_id from core.survey where site_id is not null));
create unique index on _keep (id);

create temp table _attr on commit drop as
  select site_id, jsonb_object_agg(key, coalesce(to_jsonb(value_num), to_jsonb(value_text))) a
  from (select distinct on (site_id, key) site_id, key, value_num, value_text from core.site_attribute order by site_id, key, as_of desc nulls last) x
  group by site_id;
create unique index on _attr (site_id);

create temp table _spill on commit drop as
  select a.site_id, jsonb_strip_nulls(jsonb_build_object('spills', a.spill_count, 'spill_hours', a.total_duration_hr, 'spill_year', a.year, 'edm_operating_pct', a.edm_operating_pct,
           'spills_prev', (select p.spill_count from core.discharge_annual p where p.site_id = a.site_id and p.year < a.year order by p.year desc limit 1))) a
  from (select distinct on (site_id) * from core.discharge_annual order by site_id, year desc, (spill_count is not null) desc) a;
create unique index on _spill (site_id);

create temp table _works on commit drop as
  select permit_site_id site_id, jsonb_strip_nulls(jsonb_build_object('works', 'permit', 'permit_ref', permit_ref, 'monitor_site_id', monitor_site_id, 'measured', coalesce(measured, false))) a,
         river_id, waterbody_id
  from core.sewage_works where permit_site_id is not null
  union all
  select monitor_site_id, jsonb_build_object('works', 'monitoring point', 'measured', true), river_id, waterbody_id
  from core.sewage_works where permit_site_id is null and monitor_site_id is not null;
create unique index on _works (site_id);

insert into geo.site (id, kind, name, country, operator_id, status, river_link_id, river_id, waterbody_id, snap_distance_m, dist_to_mouth_m, river_name_raw, primary_source_id, attrs, geom, geom_bng)
select s.id, s.kind, s.name, s.country, coalesce(o.company_id, s.operator_id), s.status, s.river_link_id,
       coalesce(s.river_id, wk.river_id), coalesce(s.waterbody_id, wk.waterbody_id), s.snap_distance_m, s.dist_to_mouth_m, s.river_name_raw, s.primary_source_id,
       coalesce(s.attrs, '{}')
       || coalesce(at.a, '{}')
       || coalesce((select jsonb_strip_nulls(jsonb_build_object('datum', ss.datum, 'typical_low', ss.typical_low, 'typical_high', ss.typical_high, 'highest_recent', ss.highest_recent,
                       'highest_recent_at', ss.highest_recent_at, 'max_on_record', ss.max_on_record, 'max_on_record_at', ss.max_on_record_at, 'min_on_record', ss.min_on_record))
                    from core.site_stage_scale ss where ss.site_id = s.id), '{}')
       || coalesce(o.attrs, '{}')
       || case when o.site_id is null then '{}' else jsonb_strip_nulls(jsonb_build_object('permit_ref', o.permit_ref, 'receiving', o.receiving_water_raw, 'asset_type', o.asset_type,
                       'edm_installed_on', o.edm_installed_on, 'legacy_ids', o.legacy_ids, 'shellfish_water', o.is_shellfish_water, 'bathing_site_id', o.bathing_water_site_id)) end
       || coalesce(sp.a, '{}')
       || coalesce((select jsonb_strip_nulls(jsonb_build_object('class', b.classification, 'class_year', b.year,
                       'class_prev', (select b2.classification from core.bathing_assessment b2 where b2.site_id = s.id and b2.year < b.year order by b2.year desc limit 1)))
                    from core.bathing_assessment b where b.site_id = s.id order by b.year desc limit 1), '{}')
       || coalesce(wk.a, '{}'),
       s.geom, s.geom_bng
from core.site s join _keep k on k.id = s.id
left join core.overflow o on o.site_id = s.id
left join _attr at on at.site_id = s.id
left join _spill sp on sp.site_id = s.id
left join _works wk on wk.site_id = s.id;

-- bridges (were core.poi) become sites of kind bridge
insert into geo.site (id, kind, name, river_id, waterbody_id, snap_distance_m, primary_source_id, attrs, geom, geom_bng)
select (select max(id) from geo.site) + row_number() over (order by p.id), 'bridge', p.name, p.river_id, p.waterbody_id, p.snap_distance_m, p.source_id,
       coalesce(p.attrs, '{}') || jsonb_strip_nulls(jsonb_build_object('source_key', p.source_key)), p.geom, p.geom_bng
from core.poi p where p.kind = 'bridge';

insert into geo.site_key (scheme, value, site_id)
select i.scheme, i.value, i.site_id from core.site_identifier i join _keep k on k.id = i.site_id;

insert into geo.gauge_model (site_id, normal, normal_years, beta, sd, r2, trained_through, built_at)
select g.site_id,
       (select array_agg(coalesce(n.q, array_fill(null::float8, array[21])) order by k)
        from generate_series(1, 37) k left join core.flow_normal n on n.site_id = g.site_id and n.doy = 1 + 10 * (k - 1)),
       (select max(years) from core.flow_normal n where n.site_id = g.site_id),
       p.beta, p.sd, p.r2, p.trained_through, coalesce(p.fitted_at, now())
from (select site_id from core.flow_normal union select site_id from core.flow_model_param) g
join geo.site s on s.id = g.site_id
left join core.flow_model_param p on p.site_id = g.site_id;

-- ─── live ───
insert into live.series (id, site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, qualifier, datum, matrix, fraction, method,
                         evidence_class, status, first_at, last_at, attrs, latest_at, latest_value, latest_censor, latest_quality)
select s.id, s.site_id, s.parameter_id, s.source_id, s.source_series_key, s.aggregation, s.interval_s, s.unit_id, s.native_unit, s.qualifier, s.datum, s.matrix, s.fraction, s.method,
       s.evidence_class::text, coalesce(s.status, 'active'), s.first_at, s.last_at, coalesce(s.attrs, '{}'), l.observed_at, l.value, l.censor, l.quality
from core.series s join _keep k on k.id = s.site_id left join core.observation_latest l on l.series_id = s.id;

insert into live.observation (series_id, observed_at, value, censor, quality)
select o.series_id, o.observed_at, o.value, o.censor, coalesce(o.quality, 'unchecked')
from core.observation o where o.series_id in (select id from live.series);

insert into live.site_now (site_id, kind, state, rank, at, stage, flow, flow_pct, detail, updated_at)
select g.site_id, 'gauge', g.band, g.band_rank, greatest(g.stage_at, g.flow_at), g.stage, g.flow, g.flow_pct,
       jsonb_strip_nulls(jsonb_build_object('stage_at', g.stage_at, 'flow_at', g.flow_at, 'typical_low', g.typical_low, 'typical_high', g.typical_high, 'max_on_record', g.max_on_record,
         'highest_recent', g.highest_recent, 'level_index', g.level_index, 'level_band', g.level_band, 'qmed', g.qmed, 'flow_q95', g.flow_q95, 'flow_index', g.flow_index, 'flow_band', g.flow_band)),
       coalesce(g.updated_at, now())
from core.gauge_state g join geo.site s on s.id = g.site_id;

insert into live.site_now (site_id, kind, state, at, since, detail, updated_at)
select o.site_id, 'overflow', o.status, o.reported_at, o.status_since,
       jsonb_strip_nulls(jsonb_build_object('raw_status', o.raw_status, 'last_event_start', o.last_event_start, 'last_event_end', o.last_event_end, 'source_id', o.source_id)),
       coalesce(o.fetched_at, now())
from core.overflow_status o join geo.site s on s.id = o.site_id
on conflict (site_id) do nothing;

select live.refresh_works();

insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of, summary)
select entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class::text, as_of, summary from core.signal;

insert into live.waterbody_now (waterbody_id, s, t, flow_issued_at, flow_area_km2, flow_days)
select w.id, ms.s, ms.t, f.issued_at, f.area, f.days
from geo.waterbody w
left join core.waterbody_map_state ms on ms.waterbody_id = w.id
left join lateral (
  select max(x.issued_at) issued_at, max((x.basis->>'area_km2')::float8) area,
         jsonb_agg(jsonb_strip_nulls(jsonb_build_object('at', x.valid_at, 'pct', x.flow_pct, 'q', x.flow_m3s, 'method', x.method, 'confidence', x.confidence,
                                                        'sd_z', x.basis->'sd_z', 'q_factor', x.basis->'q_factor')) order by x.valid_at) days
  from core.waterbody_flow x
  where x.waterbody_id = w.id and x.issued_at = (select max(issued_at) from core.waterbody_flow y where y.waterbody_id = w.id)) f on true;

insert into live.rain (waterbody_id, source, issued_at, step_min, at, mm)
select waterbody_id, 'radar', max(issued_at), 15, array_agg(valid_at order by valid_at), array_agg(mm order by valid_at)
from wx.catchment_rain where source = 'radar' and valid_at > now() - interval '8 days' and waterbody_id in (select id from geo.waterbody)
group by waterbody_id;
insert into live.rain (waterbody_id, source, issued_at, step_min, at, mm)
select waterbody_id, 'ifs', issued_at, max(step_min), array_agg(valid_at order by valid_at), array_agg(mm order by valid_at)
from wx.catchment_rain where source = 'ifs' and issued_at = (select max(issued_at) from wx.catchment_rain where source = 'ifs') and waterbody_id in (select id from geo.waterbody)
group by waterbody_id, issued_at;

insert into live.weather (product, issued_at, valid_at, path, bbox, legend)
select product, issued_at, valid_at, storage_path, bbox, legend from wx.frame;
insert into live.weather (product, issued_at, valid_at, lines)
select product, issued_at, valid_at, jsonb_agg(jsonb_build_object('l', level, 'g', public.ST_AsGeoJSON(geom, 3)::jsonb->'coordinates') order by level)
from wx.contour group by product, issued_at, valid_at;

insert into live.flood (kind, area_id, issued_at, statement_id, day, forecast_date, risk, attrs)
select 'outlook', f.area_id, f.issued_at, f.statement_id, f.day, f.forecast_date, f.risk, jsonb_strip_nulls(jsonb_build_object('codes', f.codes))
from core.flood_forecast f
where f.statement_id = (select statement_id from core.flood_forecast order by issued_at desc limit 1) and f.area_id in (select id from geo.area);
insert into live.flood (kind, area_id, issued_at, severity, message, changed_at, attrs)
select 'warning', a.id, w.raised_at, w.severity_level, w.message, w.changed_at, jsonb_strip_nulls(jsonb_build_object('fetched_at', w.fetched_at))
from (select distinct on (area_id) * from core.flood_warning order by area_id, changed_at desc nulls last) w
join core.flood_area fa on fa.id = w.area_id join geo.area a on a.kind = 'warning_area' and a.code = fa.code;

insert into live.survey (id, source_id, source_key, kind, site_id, waterbody_id, river_id, surveyed_at, summary_label, summary_score, breach, answers, evidence_class)
select v.id, v.source_id, v.source_key, v.kind, case when v.site_id in (select id from geo.site) then v.site_id end, v.waterbody_id, v.river_id, v.surveyed_at,
       v.summary_label, v.summary_score, v.breach,
       case when v.kind = 'citizen_weekly' then coalesce(v.answers, '{}') else jsonb_strip_nulls(jsonb_build_object('health', v.answers->'health')) end,
       coalesce(v.evidence_class::text, 'citizen_science')
from core.survey v where v.surveyed_at > now() - interval '36 months';

-- ─── ops ───
insert into ops.etl_job (name, command, interval_minutes, enabled, timeout_s, max_lag_minutes, source_slug, running_since, last_started_at, last_finished_at, last_status)
select name, command, interval_minutes, enabled, coalesce(timeout_s, 1800), max_lag_minutes, source_slug, running_since, last_started_at, last_finished_at, last_status from legacy_ops.etl_job;
-- the NRFA top-up and the normals rebuild are the only scheduled readers of the archive: one quarterly job instead of a monthly and a weekly one
delete from ops.etl_job where name in ('nrfa_recent', 'flow_normal');
insert into ops.etl_job (name, command, interval_minutes, enabled, timeout_s, max_lag_minutes, source_slug)
values ('normals', '../../.venv/bin/python -W ignore ../etl/nrfa_recent.py && ../../.venv/bin/python -W ignore ../etl/flow_normal_refresh.py', 129600, true, 7200, 200000, 'nrfa')
on conflict (name) do nothing;
insert into ops.etl_run (id, job, started_at, finished_at, status, output, request_id)
select id, job, started_at, finished_at, coalesce(status, 'running'), output, request_id from legacy_ops.etl_run where started_at > now() - interval '14 days';
insert into ops.archive_object (id, dataset, period_start, period_end, bucket, path, rows, bytes, sha256, archived_at, dropped_at)
select id, dataset, period_start, period_end, bucket, path, rows, bytes, sha256, archived_at, dropped_at from legacy_ops.archive_object;

-- identity sequences past the copied ids
do $$ declare r record; begin
  for r in select c.table_schema, c.table_name, c.column_name from information_schema.columns c
           where c.table_schema in ('ref', 'geo', 'live', 'ops') and c.is_identity = 'YES' loop
    execute format('select setval(pg_get_serial_sequence(%L, %L), greatest(1, coalesce((select max(%I) from %I.%I), 1)))',
                   r.table_schema || '.' || r.table_name, r.column_name, r.column_name, r.table_schema, r.table_name);
  end loop;
end $$;

-- ─── satellite monitoring: repoint at geo, keep everything else ───
alter table core.reach drop constraint reach_link_id_fkey;
alter table core.reach add constraint reach_link_id_fkey foreign key (link_id) references geo.river_link (id);
alter table core.reach drop constraint reach_waterbody_id_fkey;
alter table core.reach add constraint reach_waterbody_id_fkey foreign key (waterbody_id) references geo.waterbody (id);
alter function legacy_api.eo_chlorophyll(text, integer) set schema api;

-- ─── drop the old objects ───
drop schema legacy_api cascade;
drop schema legacy_ops cascade;
drop schema research cascade;
drop schema wx cascade;
drop schema ingest cascade;
drop view core.map_point;
drop function core.refresh_flow_normal(), core.refresh_flow_signals(), core.refresh_gauge_state(), core.refresh_sewage_works(), core.refresh_waterbody_map_state(),
              core.refresh_waterbody_river(), core.seasonal_pct(bigint, double precision, timestamptz), core.norm_cdf(double precision), core.norm_inv(double precision), core.ordinal(integer);
drop table core.observation, core.forecast, core.waterbody_flow,
           core.observation_latest, core.observation_daily, core.sample, core.series,
           core.gauge_state, core.gauge_flow_now, core.overflow_status, core.overflow, core.discharge_event, core.discharge_annual, core.permit,
           core.bathing_assessment, core.bathing_forecast, core.sewage_works, core.site_stage_scale, core.site_attribute, core.site_match, core.site_identifier,
           core.flow_normal, core.flow_model_param, core.survey, core.pollution_incident, core.river_obstacle,
           core.signal, core.signal_def, core.waterbody_map_state, core.waterbody_river, core.waterbody_identifier, core.waterbody_classification, core.waterbody_reason, core.waterbody_apportionment,
           core.flood_forecast, core.flood_warning, core.flood_zone, core.flood_area, core.flood_index_rule, core.flow_state_rule,
           core.boundary, core.water_area, core.beach_area, core.bridge_area, core.poi, core.map_layer, core.map_zoom_rule,
           core.site, core.river_alias, core.river_link, core.river_node, core.catchment, core.waterbody, core.river cascade;
drop schema legacy_ref cascade;
drop extension if exists ltree;
drop extension if exists vector;

-- compat views so the satellite-monitoring functions (core.build_reaches, api.eo_chlorophyll) keep reading the network by its old names
create view core.river with (security_invoker = true) as select * from geo.river;
create view core.river_link with (security_invoker = true) as select * from geo.river_link;
create view core.waterbody with (security_invoker = true) as select * from geo.waterbody;
