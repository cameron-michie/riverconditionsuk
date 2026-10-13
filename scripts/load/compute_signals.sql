-- Health sub-signals per waterbody (v0 rules, human-written; every row records its inputs in `basis`).
-- state_rank: 1 good .. 4 bad; unknown rows are written so the map can show "no data" honestly.
truncate live.signal;
create temp table st_rank (n text, r smallint, s text);
insert into st_rank values ('high',1,'good'),('good',1,'good'),('moderate',2,'moderate'),('poor',3,'poor'),('bad',4,'bad');

-- current + previous rated classification per element, as folded onto geo.waterbody.classes by the loaders
create temp table cls as
select w.id waterbody_id, c.key element_code, (c.value->>'cycle')::int as cycle, (c.value->>'year')::int as year, c.value->>'status' status,
       (c.value->>'rank')::smallint status_rank, (c.value->>'prev_rank')::smallint prev_rank
from geo.waterbody w cross join lateral jsonb_each(w.classes) c where c.value ? 'rank';
create index on cls (waterbody_id);

-- chemical = worst of phosphate / ammonia / dissolved oxygen / pH / temperature
insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of)
select 'waterbody', waterbody_id, 'chemical',
  case when mx = 1 or mx = 2 then 'good' when mx = 3 then 'moderate' when mx = 4 then 'poor' else 'bad' end,
  case when mx <= 2 then 1 when mx = 3 then 2 when mx = 4 then 3 else 4 end,
  case when pmx is null then 'unknown' when mx < pmx then 'improving' when mx > pmx then 'worsening' else 'stable' end,
  jsonb_build_object('rule','worst of phosphate, ammonia, dissolved_oxygen, ph, temperature (WFD class)','elements',els,'cycle',cyc),
  'regulator_assessment', now()
from (select waterbody_id, max(status_rank) mx, max(prev_rank) pmx, max(cycle) cyc,
        jsonb_object_agg(element_code, jsonb_build_object('status', status, 'year', year, 'cycle', cycle)) els
      from cls where element_code in ('phosphate','ammonia','dissolved_oxygen','ph','temperature') group by 1) q;

-- ecological = ecological class; fall back to worst biological element
insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of)
select 'waterbody', w.waterbody_id, 'ecological',
  case when w.rk <= 2 then 'good' when w.rk = 3 then 'moderate' when w.rk = 4 then 'poor' else 'bad' end,
  case when w.rk <= 2 then 1 when w.rk = 3 then 2 when w.rk = 4 then 3 else 4 end,
  case when w.prk is null then 'unknown' when w.rk < w.prk then 'improving' when w.rk > w.prk then 'worsening' else 'stable' end,
  jsonb_build_object('rule', w.rule, 'cycle', w.cyc, 'riverfly_breaches_24m', coalesce(rf.n_breach, 0), 'riverfly_surveys_24m', coalesce(rf.n, 0)),
  'regulator_assessment', now()
from (
  select waterbody_id,
         coalesce(max(status_rank) filter (where element_code = 'ecological'), max(status_rank) filter (where element_code in ('fish','invertebrates','macrophytes_phytobenthos'))) rk,
         coalesce(max(prev_rank) filter (where element_code = 'ecological'), max(prev_rank) filter (where element_code in ('fish','invertebrates','macrophytes_phytobenthos'))) prk,
         max(cycle) cyc,
         case when bool_or(element_code = 'ecological') then 'WFD ecological class' else 'worst of fish / invertebrates / macrophytes+phytobenthos' end rule
  from cls where element_code in ('ecological','fish','invertebrates','macrophytes_phytobenthos') group by 1) w
left join (select waterbody_id, count(*) n, count(*) filter (where breach) n_breach from live.survey
           where kind = 'riverfly_rmi' and surveyed_at > now() - interval '24 months' group by 1) rf on rf.waterbody_id = w.waterbody_id
where w.rk is not null;

-- sewage pressure
create temp table sew as
with ov as (
  select s.waterbody_id,
         count(*) n_overflows,
         count(*) filter (where n.state = 'discharging') n_discharging_now,
         count(*) filter (where n.state = 'offline') n_offline,
         avg((s.attrs->>'spills')::numeric) avg_spills_2025,
         max((s.attrs->>'spills')::int) max_spills_2025,
         sum((s.attrs->>'spill_hours')::numeric) hours_2025,
         avg((s.attrs->>'spills_prev')::numeric) avg_spills_prev
  from geo.site s left join live.site_now n on n.site_id = s.id
  where s.kind = 'storm_overflow' and s.waterbody_id is not null group by 1),
ap as (select w.id waterbody_id, sum((a->>'share_pct')::numeric) filter (where a->>'sector' in ('sewage_works','storm_tanks','combined_sewer_overflows')) share
       from geo.waterbody w cross join lateral jsonb_array_elements(w.apportionment) a where a->>'pollutant' = 'phosphorus' group by 1),
rn as (select w.id waterbody_id, count(*) n from geo.waterbody w cross join lateral jsonb_array_elements(w.reasons) r where r->>'sector' = 'water_industry' group by 1)
select w.id waterbody_id, ov.n_overflows, ov.n_discharging_now, ov.n_offline, ov.avg_spills_2025, ov.max_spills_2025, ov.hours_2025, ov.avg_spills_prev, ap.share p_share, coalesce(rn.n, 0) rnag_water_industry
from geo.waterbody w left join ov on ov.waterbody_id = w.id left join ap on ap.waterbody_id = w.id left join rn on rn.waterbody_id = w.id
where ov.waterbody_id is not null or ap.waterbody_id is not null or rn.waterbody_id is not null;
insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of)
select 'waterbody', waterbody_id, 'sewage_pressure',
  case lvl when 1 then 'good' when 2 then 'moderate' when 3 then 'poor' else 'bad' end, lvl,
  case when avg_spills_prev is null or avg_spills_2025 is null then 'unknown' when avg_spills_2025 > avg_spills_prev * 1.15 then 'worsening' when avg_spills_2025 < avg_spills_prev * 0.85 then 'improving' else 'stable' end,
  jsonb_build_object('rule','max of: modelled P share from sewage sectors (>=10/25/50%), mean 2025 spills per overflow (>=20/40/60), official water-industry reasons for failure (>=1)',
     'n_overflows', n_overflows, 'discharging_now', n_discharging_now, 'offline', n_offline, 'avg_spills_2025', round(avg_spills_2025::numeric, 1), 'max_spills_2025', max_spills_2025,
     'hours_2025', round(hours_2025::numeric), 'modelled_p_share_pct', round(p_share::numeric, 1), 'rnag_water_industry', rnag_water_industry),
  case when avg_spills_2025 is not null then 'company_reported' else 'modelled' end, now()
from (select *, greatest(
        case when p_share >= 50 then 4 when p_share >= 25 then 3 when p_share >= 10 then 2 when p_share is not null then 1 else 0 end,
        case when avg_spills_2025 >= 60 then 4 when avg_spills_2025 >= 40 then 3 when avg_spills_2025 >= 20 then 2 when avg_spills_2025 is not null then 1 else 0 end,
        case when rnag_water_industry > 0 then 2 else 0 end) lvl from sew) q where lvl > 0;

-- agricultural pressure (modelled share + official reasons; inferred landscape risk, never field attribution)
insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of)
select 'waterbody', waterbody_id, 'agricultural_pressure',
  case lvl when 1 then 'good' when 2 then 'moderate' when 3 then 'poor' else 'bad' end, lvl, 'unknown',
  jsonb_build_object('rule','max of: modelled agricultural share of P load (>=20/40/60%), official agriculture reasons for failure (>=1 -> at least moderate)',
     'modelled_p_agri_pct', round(p_ag::numeric, 1), 'modelled_n_agri_pct', round(n_ag::numeric, 1), 'modelled_sediment_agri_pct', round(s_ag::numeric, 1), 'rnag_agriculture', rn_ag, 'nutrient_neutrality_zone', nn),
  'modelled', now()
from (
  select w.id waterbody_id,
    max(a.share_pct) filter (where a.pollutant = 'phosphorus' and a.sector = 'agriculture') p_ag,
    max(a.share_pct) filter (where a.pollutant = 'nitrogen' and a.sector = 'agriculture') n_ag,
    max(a.share_pct) filter (where a.pollutant = 'sediment' and a.sector = 'agriculture') s_ag,
    (select count(*) from jsonb_array_elements(w.reasons) r where r->>'sector' = 'agriculture') rn_ag,
    exists (select 1 from geo.area c where c.kind = 'nutrient_neutrality' and c.geom is not null and ST_Intersects(c.geom, ST_PointOnSurface(w.catchment_geom))) nn,
    greatest(
      case when max(a.share_pct) filter (where a.pollutant = 'phosphorus' and a.sector = 'agriculture') >= 60 then 4
           when max(a.share_pct) filter (where a.pollutant = 'phosphorus' and a.sector = 'agriculture') >= 40 then 3
           when max(a.share_pct) filter (where a.pollutant = 'phosphorus' and a.sector = 'agriculture') >= 20 then 2
           when max(a.share_pct) filter (where a.pollutant = 'phosphorus' and a.sector = 'agriculture') is not null then 1 else 0 end,
      case when (select count(*) from jsonb_array_elements(w.reasons) r where r->>'sector' = 'agriculture') > 0 then 2 else 0 end) lvl
  from geo.waterbody w
  left join lateral (select x->>'pollutant' pollutant, x->>'sector' sector, (x->>'share_pct')::numeric share_pct from jsonb_array_elements(w.apportionment) x) a on true
  group by w.id, w.catchment_geom, w.reasons) q where lvl > 0;

-- algal / visual: citizen perception (Big River Watch, last 36 months). Perception, not measurement.
insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of)
select 'waterbody', waterbody_id, 'algal_visual',
  case when share >= 0.5 then 'poor' when share >= 0.25 then 'moderate' else 'good' end,
  case when share >= 0.5 then 3 when share >= 0.25 then 2 else 1 end, 'unknown',
  jsonb_build_object('rule','share of Big River Watch surveys in 36 months answering Unhealthy (n>=3): >=25% moderate, >=50% poor','surveys', n, 'unhealthy', unhealthy,
     'algae_reported', algae, 'very_or_quite_murky', murky),
  'citizen_science', now()
from (select waterbody_id, count(*) n, count(*) filter (where answers->>'health' = 'Unhealthy') unhealthy,
             (count(*) filter (where answers->>'health' = 'Unhealthy'))::numeric / count(*) share,
             count(*) filter (where answers->>'plants_algae' = 'Yes' or answers->>'pollution_algal' = 'Yes') algae,
             count(*) filter (where answers->>'turbidity' in ('Quite_murky','Very_murky')) murky
      from live.survey where kind = 'big_river_watch' and waterbody_id is not null and surveyed_at > now() - interval '36 months' group by 1 having count(*) >= 3) q;

-- river-level roll-up: worst state among waterbodies carrying >=10% of the river's length
insert into live.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of)
select 'river', r.river_id, s.signal_code,
  (array['good','moderate','poor','bad'])[max(s.state_rank)], max(s.state_rank), 'unknown',
  jsonb_build_object('rule','worst waterbody state among waterbodies covering >=10% of the river','waterbodies', jsonb_agg(distinct r.waterbody_id)),
  (array_agg(s.evidence_class order by s.state_rank desc))[1], now()
from (select river_id, waterbody_id, sum(length_m) len, sum(sum(length_m)) over (partition by river_id) tot
      from geo.river_link where river_id is not null and waterbody_id is not null group by 1, 2) r
join live.signal s on s.entity_kind = 'waterbody' and s.entity_id = r.waterbody_id and s.state <> 'unknown'
where r.len / nullif(r.tot, 0) >= 0.1 group by r.river_id, s.signal_code;


-- ───────────── plain-English reasons ─────────────
update live.signal s set summary =
  (select string_agg(case k when 'ph' then 'pH' else replace(initcap(replace(k, '_', ' ')), 'Dissolved Oxygen', 'Dissolved oxygen') end || ': ' || (v->>'status') || ' status', ', ' order by k) from jsonb_each(s.basis->'elements') e(k, v))
  || ' (WFD classification, cycle ' || (s.basis->>'cycle') || ').'
where signal_code = 'chemical' and entity_kind = 'waterbody';

update live.signal s set summary =
  case when s.basis->>'rule' like 'WFD ecological%' then 'Ecological class ' || s.state else 'Worst of fish, invertebrates and plants: ' || s.state end || ' (WFD, cycle ' || (s.basis->>'cycle') || ').'
  || case when (s.basis->>'riverfly_surveys_24m')::int > 0 then ' Riverfly volunteers: ' || (s.basis->>'riverfly_breaches_24m') || ' breaches in ' || (s.basis->>'riverfly_surveys_24m') || ' surveys over two years.' else '' end
where signal_code = 'ecological' and entity_kind = 'waterbody';

update live.signal s set summary = trim(both ' ' from
  case when (s.basis->>'n_overflows') is not null then (s.basis->>'n_overflows') || ' storm overflows' ||
       case when s.basis->>'avg_spills_2025' is not null then ', averaging ' || (s.basis->>'avg_spills_2025') || ' spills each in 2025 (company-reported).' else '.' end else '' end ||
  case when (s.basis->>'discharging_now')::int > 0 then ' ' || (s.basis->>'discharging_now') || ' discharging now.' else '' end ||
  case when s.basis->>'modelled_p_share_pct' is not null then ' Modelled: ' || (s.basis->>'modelled_p_share_pct') || '% of phosphorus from sewage sources.' else '' end ||
  case when (s.basis->>'rnag_water_industry')::int > 0 then ' The regulator names the water industry as a reason for failure.' else '' end)
where signal_code = 'sewage_pressure' and entity_kind = 'waterbody';

update live.signal s set summary = trim(both ' ' from
  case when s.basis->>'modelled_p_agri_pct' is not null then 'Modelled: ' || (s.basis->>'modelled_p_agri_pct') || '% of phosphorus from agriculture.' else '' end ||
  case when (s.basis->>'rnag_agriculture')::int > 0 then ' The regulator names agriculture in ' || (s.basis->>'rnag_agriculture') || ' reason(s) for failure.' else '' end ||
  case when (s.basis->>'nutrient_neutrality_zone')::boolean then ' In a nutrient neutrality catchment.' else '' end || ' A landscape estimate, not attribution to any farm.')
where signal_code = 'agricultural_pressure' and entity_kind = 'waterbody';

update live.signal s set summary = (s.basis->>'unhealthy') || ' of ' || (s.basis->>'surveys') || ' Big River Watch surveys in three years called it unhealthy' ||
  case when (s.basis->>'algae_reported')::int > 0 then '; ' || (s.basis->>'algae_reported') || ' mention algae' else '' end || ' (volunteer perception).'
where signal_code = 'algal_visual' and entity_kind = 'waterbody';

-- river level: name the worst stretch
update live.signal s set summary = 'Worst stretch: ' || q.name || ' (' || coalesce(q.word, q.state) || ').'
from (select distinct on (r.entity_id, r.signal_code) r.entity_id rid, r.signal_code code, wb.name, sg.state, (select d.words[sg.state_rank] from ref.signal d where d.code = r.signal_code) word
      from live.signal r cross join lateral jsonb_array_elements_text(r.basis->'waterbodies') j(id)
      join live.signal sg on sg.entity_kind = 'waterbody' and sg.entity_id = j.id::bigint and sg.signal_code = r.signal_code
      join geo.waterbody wb on wb.id = sg.entity_id
      where r.entity_kind = 'river' order by r.entity_id, r.signal_code, sg.state_rank desc) q
where s.entity_kind = 'river' and s.entity_id = q.rid and s.signal_code = q.code;

select live.refresh_flow_signals();      -- flow is recomputed with everything else; this also refreshes live.waterbody_now
analyze live.signal;
select signal_code, entity_kind, count(*) n, count(*) filter (where state='good') good, count(*) filter (where state='moderate') mod, count(*) filter (where state='poor') poor, count(*) filter (where state='bad') bad from live.signal group by 1,2 order by 2,1;
