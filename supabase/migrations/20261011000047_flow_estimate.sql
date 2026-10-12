-- Flow relative to normal for every stretch.
--   measured:  a gauge on the same river (60 km along it, 120 km on rivers over 150 km long)
--   estimated: regional percentile transfer. Standard practice for ungauged catchments: convert each nearby gauge's seasonal flow percentile to a
--              normal score, average the scores weighted by closeness and similar river size, convert back. Marked as modelled.
create or replace function core.norm_inv(p double precision) returns double precision language plpgsql immutable as $$
declare q double precision; t double precision;   -- Abramowitz and Stegun 26.2.23
begin
  p := least(0.999, greatest(0.001, p));
  q := case when p < 0.5 then p else 1 - p end; t := sqrt(-2 * ln(q));
  t := t - (2.515517 + 0.802853 * t + 0.010328 * t * t) / (1 + 1.432788 * t + 0.189269 * t * t + 0.001308 * t * t * t);
  return case when p < 0.5 then -t else t end;
end $$;
create or replace function core.norm_cdf(z double precision) returns double precision language plpgsql immutable as $$
declare t double precision := 1 / (1 + 0.2316419 * abs(z)); d double precision := 0.3989423 * exp(-z * z / 2); pr double precision;
begin
  pr := d * t * (0.319381530 + t * (-0.356563782 + t * (1.781477937 + t * (-1.821255978 + t * 1.330274429))));
  return case when z > 0 then 1 - pr else pr end;
end $$;

create or replace function core.refresh_flow_signals() returns void language plpgsql as $$
begin
  delete from core.signal where signal_code = 'flow';
  create temp table _wb on commit drop as
    select l.waterbody_id wid, (array_agg(l.river_id order by rl.len desc nulls last))[1] river_id, avg(l.dist_to_mouth_m) ch, round(avg(l.size_class))::int sz,
           ST_Centroid(ST_Collect(ST_LineInterpolatePoint(l.geom, 0.5))) pt
    from core.river_link l left join (select waterbody_id wb, river_id rid, sum(length_m) len from core.river_link group by 1, 2) rl on rl.wb = l.waterbody_id and rl.rid = l.river_id
    where l.waterbody_id is not null group by l.waterbody_id;
  alter table _wb add column rname text; update _wb w set rname = r.name from core.river r where r.id = w.river_id;
  create temp table _g on commit drop as
    select s.id gid, s.name, s.river_id, r.name rname, s.waterbody_id, s.dist_to_mouth_m ch, g.flow, g.flow_pct, g.qmed, s.geom pt, coalesce(l.size_class, 0) sz, r.length_km rlen
    from core.gauge_state g join core.site s on s.id = g.site_id left join core.river_link l on l.id = s.river_link_id left join core.river r on r.id = s.river_id
    where g.flow_pct is not null and g.flow_at > now() - interval '10 days';
  -- measured
  create temp table _m on commit drop as
    select w.wid, g.gid, g.name gname, g.flow, g.flow_pct pct, g.waterbody_id = w.wid on_stretch, round((ST_Distance(g.pt::geography, w.pt::geography) / 1000)::numeric) km, g.ch > w.ch upstream
    from _wb w
    join lateral (select * from _g g where g.river_id is not null and (g.waterbody_id = w.wid
                    or (g.rname = w.rname and ST_Distance(g.pt::geography, w.pt::geography) <= case when g.rlen > 150 then 100000 else 50000 end))
                  order by (g.waterbody_id = w.wid) desc, ST_Distance(g.pt::geography, w.pt::geography) limit 1) g on true;
  -- estimated: weighted normal score of nearby gauges
  create temp table _e on commit drop as
    with cand as (
      select w.wid, g.gid, g.name, g.flow_pct, ST_Distance(w.pt::geography, g.pt::geography) / 1000 d, abs(g.sz - coalesce(w.sz, 0)) dsz
      from _wb w join _g g on ST_DWithin(w.pt::geography, g.pt::geography, 80000)
      where w.wid not in (select wid from _m)),
    ranked as (select *, row_number() over (partition by wid order by d + 4 * dsz) rn, 1 / power(d + 10, 2) * exp(-0.6 * dsz) w, core.norm_inv(least(99.5, greatest(0.5, flow_pct)) / 100) z from cand)
    select wid, count(*) n, min(d) near, sum(w * z) / sum(w) zbar, sqrt(greatest(0, sum(w * z * z) / sum(w) - power(sum(w * z) / sum(w), 2))) spread,
           jsonb_agg(jsonb_build_object('gauge', gid, 'name', name, 'km', round(d::numeric), 'pct', round(flow_pct::numeric)) order by rn) donors
    from ranked where rn <= 5 group by wid having (count(*) >= 2 and min(d) <= 60) or min(d) <= 20;
  insert into core.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of, summary)
  select 'waterbody', m.wid, 'flow', r.band, r.rank, 'unknown',
         jsonb_build_object('method', 'measured', 'gauge', m.gid, 'gauge_name', m.gname, 'pct', round(m.pct::numeric), 'flow', round(m.flow::numeric, 3), 'on_stretch', m.on_stretch, 'km_along_river', m.km),
         'official_monitoring', now(),
         'Flow at ' || m.gname || case when m.on_stretch then '' else ' (' || m.km || ' km ' || case when m.upstream then 'upstream' else 'downstream' end || ' on the same river)' end
           || ' is ' || r.label || ': ' || core.ordinal(round(m.pct::numeric)::int) || ' percentile for the time of year.'
  from _m m join lateral (select * from core.flow_state_rule r where r.from_pct <= m.pct order by r.from_pct desc limit 1) r on true;
  insert into core.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of, summary)
  select 'waterbody', e.wid, 'flow', r.band, r.rank, 'unknown',
         jsonb_build_object('method', 'estimated', 'pct', round(p::numeric), 'donors', e.donors, 'n', e.n, 'nearest_km', round(e.near::numeric),
                            'confidence', case when e.n >= 3 and e.near <= 25 and e.spread < 0.8 then 'medium' else 'low' end),
         'modelled', now(),
         'Estimated from ' || e.n || ' nearby gauge' || case when e.n > 1 then 's' else '' end || ' (nearest ' || round(e.near::numeric) || ' km): ' || r.label || ', about the ' || core.ordinal(round(p::numeric)::int) || ' percentile for the time of year.'
  from (select e.*, 100 * core.norm_cdf(e.zbar) p from _e e) e
  join lateral (select * from core.flow_state_rule r where r.from_pct <= e.p order by r.from_pct desc limit 1) r on true;
  -- rivers: average of their stretches
  insert into core.signal (entity_kind, entity_id, signal_code, state, state_rank, trend, basis, evidence_class, as_of, summary)
  select 'river', x.river_id, 'flow', r.band, r.rank, 'unknown', jsonb_build_object('stretches', x.n, 'measured', x.nm), case when x.nm > 0 then 'official_monitoring' else 'modelled' end::core.evidence_class, now(),
         'Average over ' || x.n || ' stretch' || case when x.n > 1 then 'es' else '' end || ' (' || x.nm || ' measured, ' || (x.n - x.nm) || ' estimated): ' || r.label || '.'
  from (select w.river_id, count(*) n, count(*) filter (where s.basis ->> 'method' = 'measured') nm, round(avg(s.state_rank))::int rk
        from core.signal s join _wb w on w.wid = s.entity_id where s.entity_kind = 'waterbody' and s.signal_code = 'flow' and w.river_id is not null group by w.river_id) x
  join core.flow_state_rule r on r.rank = x.rk;
  perform core.refresh_waterbody_map_state();
end $$;
