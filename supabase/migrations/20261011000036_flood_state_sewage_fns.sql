-- Rebuilds core.gauge_state from the latest readings, stage scales, NRFA flood statistics and the rules in core.flood_index_rule.
create or replace function core.refresh_gauge_state() returns void language plpgsql as $$
begin
  truncate core.gauge_state;
  insert into core.gauge_state (site_id, stage, stage_at, typical_low, typical_high, max_on_record, highest_recent, level_index, level_band,
                                flow, flow_at, flow_pct, qmed, flow_q95, flow_index, flow_band, band, band_rank)
  with lv as (
    select distinct on (s.site_id) s.site_id, l.value, l.observed_at, s.datum
    from core.series s join ref.parameter p on p.id = s.parameter_id and p.code = 'water_level'
    join core.observation_latest l on l.series_id = s.id
    where s.source_id = (select id from ingest.source where slug = 'ea_flood_monitoring') and l.value is not null and l.observed_at > now() - interval '10 days'
    order by s.site_id, (s.qualifier ilike 'stage') desc, (s.datum = 'mASD') desc, l.observed_at desc),
  fl as (
    select distinct on (s.site_id) s.site_id, l.value, l.observed_at
    from core.series s join ref.parameter p on p.id = s.parameter_id and p.code = 'river_flow'
    join core.observation_latest l on l.series_id = s.id
    where s.source_id in (select id from ingest.source where slug in ('ea_flood_monitoring', 'ea_hydrology')) and l.value is not null and l.observed_at > now() - interval '10 days'
    order by s.site_id, l.observed_at desc),
  at as (select site_id, max(value_num) filter (where key = 'qmed') qmed, max(value_num) filter (where key = 'gdf_q95_flow') q95, max(value_num) filter (where key = 'gdf_q50_flow') q50,
                max(value_num) filter (where key = 'gdf_q10_flow') q10, max(value_num) filter (where key = 'gdf_q05_flow') q05 from core.site_attribute group by site_id),
  old as (select distinct on (site_id) site_id, pct_of_record from core.gauge_flow_now order by site_id),
  base as (
    select coalesce(lv.site_id, fl.site_id) site_id, lv.observed_at stage_at, fl.value flow, fl.observed_at flow_at,
           ss.typical_low, ss.typical_high, ss.max_on_record, ss.highest_recent,
           -- the stage scale is in stage units; some series are in metres above Ordnance Datum. Take whichever reading sits inside the station's envelope.
           case when ss.site_id is null or lv.value is null then null
                when lv.value between ss.min_on_record - 0.5 and ss.max_on_record + 1.0 then lv.value
                when ss.datum is not null and lv.value - ss.datum between ss.min_on_record - 0.5 and ss.max_on_record + 1.0 then lv.value - ss.datum end stage,
           at.qmed, at.q95, at.q50, at.q10, at.q05, old.pct_of_record
    from lv full join fl on fl.site_id = lv.site_id
    left join core.site_stage_scale ss on ss.site_id = coalesce(lv.site_id, fl.site_id)
    left join at on at.site_id = coalesce(lv.site_id, fl.site_id) left join old on old.site_id = coalesce(lv.site_id, fl.site_id)),
  calc as (
    select b.*, case when b.stage is not null and b.max_on_record > b.typical_high then (b.stage - b.typical_high) / (b.max_on_record - b.typical_high) end lidx,
           case when b.flow is not null and b.qmed > 0 then b.flow / b.qmed end fidx,
           case when b.flow is null then null
                when b.q95 is not null and b.q50 is not null and b.q10 is not null and b.q05 is not null then
                  case when b.flow <= b.q95 then 5 * b.flow / nullif(b.q95, 0) when b.flow <= b.q50 then 5 + 45 * (b.flow - b.q95) / nullif(b.q50 - b.q95, 0)
                       when b.flow <= b.q10 then 50 + 40 * (b.flow - b.q50) / nullif(b.q10 - b.q50, 0) when b.flow <= b.q05 then 90 + 5 * (b.flow - b.q10) / nullif(b.q05 - b.q10, 0) else 95 + least(5, 5 * (b.flow - b.q05) / nullif(b.q05, 0)) end
                else b.pct_of_record * 100 end fpct
    from base b),
  banded as (
    select c.*, case when c.stage is null then null when c.stage < c.typical_low then 'low' else (select r.band from core.flood_index_rule r where r.kind = 'level' and r.from_index <= coalesce(c.lidx, -1000) order by r.from_index desc limit 1) end lband,
           case when c.flow is null then null when c.q95 is not null and c.flow <= c.q95 then 'low' when c.fidx is null then null else (select r.band from core.flood_index_rule r where r.kind = 'flow' and r.from_index <= c.fidx order by r.from_index desc limit 1) end fband
    from calc c)
  select site_id, stage, stage_at, typical_low, typical_high, max_on_record, highest_recent, lidx, lband, flow, flow_at, fpct, qmed, q95, fidx, fband,
         case greatest(coalesce(array_position(array['low','normal','elevated','high','severe'], lband), 0), coalesce(array_position(array['low','normal','elevated','high','severe'], fband), 0)) when 1 then 'low' when 2 then 'normal' when 3 then 'elevated' when 4 then 'high' when 5 then 'severe' end,
         greatest(coalesce(array_position(array['low','normal','elevated','high','severe'], lband), 0), coalesce(array_position(array['low','normal','elevated','high','severe'], fband), 0))
  from banded where greatest(coalesce(array_position(array['low','normal','elevated','high','severe'], lband), 0), coalesce(array_position(array['low','normal','elevated','high','severe'], fband), 0)) > 0;
end $$;

-- Where treated sewage is discharged (water-company works) and whether the effluent is monitored.
create or replace function core.refresh_sewage_works() returns void language plpgsql as $$
begin
  truncate core.sewage_works restart identity;
  insert into core.sewage_works (name, company_id, permit_ref, receiving_water_raw, geom, geom_bng, permit_site_id, river_id, waterbody_id, attrs)
  select s.name, s.operator_id, (select p.permit_ref from core.permit p where p.site_id = s.id order by p.version desc nulls last limit 1), s.river_name_raw, s.geom, s.geom_bng, s.id, s.river_id, s.waterbody_id, jsonb_build_object('basis', 'permit')
  from core.site s where s.kind = 'sewage_works' and s.merged_into is null and s.attrs->>'permit_type' = 'WwTW/Sewage Treatment Works (water company)';
  insert into core.sewage_works (name, receiving_water_raw, geom, geom_bng, monitor_site_id, river_id, waterbody_id, measured, attrs)
  select m.name, m.river_name_raw, m.geom, m.geom_bng, m.id, m.river_id, m.waterbody_id, true, jsonb_build_object('basis', 'monitoring point')
  from core.site m where m.kind = 'sewage_works' and m.merged_into is null and m.attrs->>'wq_type' like 'SEWAGE DISCHARGES - FINAL/TREATED EFFLUENT - WATER COMPANY%'
    and not exists (select 1 from core.sewage_works w where w.geom_bng && ST_Expand(m.geom_bng, 150) and ST_DWithin(w.geom_bng, m.geom_bng, 150));
  update core.sewage_works w set monitor_site_id = x.mid, measured = true
  from (select distinct on (w2.id) w2.id wid, m.id mid from core.sewage_works w2
        join core.site m on m.kind = 'sewage_works' and m.attrs->>'wq_type' like 'SEWAGE DISCHARGES - FINAL/TREATED EFFLUENT - WATER COMPANY%' and m.geom_bng && ST_Expand(w2.geom_bng, 150) and ST_DWithin(m.geom_bng, w2.geom_bng, 150)
        where w2.monitor_site_id is null and w2.permit_site_id is not null order by w2.id, ST_Distance(m.geom_bng, w2.geom_bng)) x where x.wid = w.id;
  -- nearest watercourse for works that were not snapped
  update core.sewage_works w set river_id = n.river_id, waterbody_id = n.waterbody_id
  from (select w2.id wid, (select l.river_id from core.river_link l order by l.geom_bng <-> w2.geom_bng limit 1) river_id, (select l.waterbody_id from core.river_link l order by l.geom_bng <-> w2.geom_bng limit 1) waterbody_id
        from core.sewage_works w2 where w2.river_id is null) n where n.wid = w.id;
  -- latest effluent readings, kept on the row so tiles stay cheap
  update core.sewage_works w set attrs = w.attrs || jsonb_build_object('latest', x.latest, 'latest_at', x.at)
  from (select s.site_id, jsonb_object_agg(p.code, jsonb_build_object('v', l.value, 'c', l.censor, 'u', u.symbol)) latest, max(l.observed_at) at
        from core.series s join ref.parameter p on p.id = s.parameter_id join ref.unit u on u.id = s.unit_id join core.observation_latest l on l.series_id = s.id
        where s.matrix = 'effluent' and p.code in ('ammonia_total_n', 'bod5', 'suspended_solids', 'phosphorus_total') and (l.value is not null or l.censor is not null) group by s.site_id) x
  where x.site_id = w.monitor_site_id;
end $$;
