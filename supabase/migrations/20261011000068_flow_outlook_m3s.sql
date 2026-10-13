-- flow_outlook now carries the modelled flow in m3/s with its uncertainty factor (x1.3 where a gauge sits on the stretch, x2 where flow is scaled from neighbours).
create or replace function api.flow_outlook(p_waterbody bigint) returns jsonb
language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object(
    'issued_at', max(f.issued_at),
    'evidence', 'modelled',
    'area_km2', max((f.basis->>'area_km2')::numeric),
    'days', jsonb_agg(jsonb_build_object('at', f.valid_at, 'pct', round(f.flow_pct), 'band', r.band, 'label', r.label, 'method', f.method, 'confidence', f.confidence, 'sd_z', f.basis->'sd_z',
                                         'q', round(f.flow_m3s::numeric, case when f.flow_m3s < 1 then 3 else 2 end), 'q_factor', f.basis->'q_factor') order by f.valid_at))
  from core.waterbody_flow f
  join lateral (select * from core.flow_state_rule r where r.from_pct <= f.flow_pct order by r.from_pct desc limit 1) r on true
  where f.waterbody_id = p_waterbody and f.issued_at = (select max(issued_at) from core.waterbody_flow where waterbody_id = p_waterbody);
$$;
