-- Read side of the forecast tables, for the forecast view the app will get later. Modelled, so every row carries its method and confidence.
create or replace function api.flow_outlook(p_waterbody bigint) returns jsonb
language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object(
    'issued_at', max(f.issued_at),
    'evidence', 'modelled',
    'days', jsonb_agg(jsonb_build_object('at', f.valid_at, 'pct', round(f.flow_pct), 'band', r.band, 'label', r.label, 'method', f.method, 'confidence', f.confidence, 'sd_z', f.basis->'sd_z') order by f.valid_at))
  from core.waterbody_flow f
  join lateral (select * from core.flow_state_rule r where r.from_pct <= f.flow_pct order by r.from_pct desc limit 1) r on true
  where f.waterbody_id = p_waterbody and f.issued_at = (select max(issued_at) from core.waterbody_flow where waterbody_id = p_waterbody);
$$;
create or replace function api.gauge_outlook(p_site bigint) returns jsonb
language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object('issued_at', max(f.issued_at), 'unit', 'm3/s', 'evidence', 'modelled',
    'days', jsonb_agg(jsonb_build_object('at', f.valid_at, 'q', round(f.value::numeric, 3), 'p10', round(f.p10::numeric, 3), 'p90', round(f.p90::numeric, 3)) order by f.valid_at))
  from core.forecast f join core.series s on s.id = f.series_id
  where s.site_id = p_site and f.issued_at = (select max(f2.issued_at) from core.forecast f2 join core.series s2 on s2.id = f2.series_id where s2.site_id = p_site);
$$;
grant execute on function api.flow_outlook(bigint), api.gauge_outlook(bigint) to anon, authenticated;
