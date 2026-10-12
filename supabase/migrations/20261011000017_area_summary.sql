-- "What is happening in the area I am looking at." Called for the current viewport; refuses very wide views (use zoom).
create function api.area_summary(p_minx double precision, p_miny double precision, p_maxx double precision, p_maxy double precision) returns jsonb
language plpgsql stable security definer set search_path = core, ref, public, pg_temp as $$
declare env geometry := ST_MakeEnvelope(p_minx, p_miny, p_maxx, p_maxy, 4326); r jsonb;
begin
  if (p_maxx - p_minx) > 4.5 or (p_maxy - p_miny) > 3.5 then
    return jsonb_build_object('too_wide', true);
  end if;
  select jsonb_build_object(
    'overflows', (select jsonb_build_object('n', count(*), 'discharging', count(*) filter (where props->>'st' = 'discharging'), 'offline', count(*) filter (where props->>'st' = 'offline'),
        'spills_2025', coalesce(sum((props->>'sp')::int), 0),
        'worst', (select coalesce(jsonb_agg(jsonb_build_object('n', w.props->>'n', 'co', w.props->>'co', 'sp', (w.props->>'sp')::int, 'hr', (w.props->>'hr')::int, 'st', w.props->>'st', 'x', ST_X(w.geom), 'y', ST_Y(w.geom))), '[]')
                  from (select * from core.map_point m2 where m2.layer = 'overflows' and m2.geom && env and m2.props->>'sp' is not null order by (m2.props->>'sp')::int desc limit 5) w))
      from core.map_point m where m.layer = 'overflows' and m.geom && env),
    'stretches', (select coalesce(jsonb_object_agg(z.code, z.arr), '{}') from (
        select d.code, jsonb_agg(c.cnt order by k) arr
        from core.signal_def d cross join generate_series(0, 4) k
        cross join lateral (select count(*) cnt from core.waterbody w join core.waterbody_map_state ms on ms.waterbody_id = w.id
                            where w.line_geom && env and substr(ms.s, d.sort::int, 1)::int = k) c
        group by d.code) z),
    'rivers', (select coalesce(jsonb_agg(jsonb_build_object('slug', q.slug, 'n', q.name, 'km', q.km, 's', q.s) order by q.km desc), '[]')
      from (select r.slug, r.name, round(r.length_km::numeric) km,
                   (select string_agg(coalesce(sg.state_rank::text, '0'), '' order by d.sort) from core.signal_def d left join core.signal sg on sg.entity_kind = 'river' and sg.entity_id = r.id and sg.signal_code = d.code) s
            from core.river r where r.geom && env and r.length_km >= 8 order by r.length_km desc limit 8) q),
    'bathing', (select coalesce(jsonb_agg(jsonb_build_object('n', props->>'n', 'cl', props->>'cl', 'ec', props->>'ec', 'cn', props->>'cn', 'x', ST_X(geom), 'y', ST_Y(geom))), '[]')
      from (select * from core.map_point where layer = 'bathing' and geom && env order by (props->>'n') limit 8) b),
    'gauges', (select jsonb_build_object('n', count(*), 'low', count(*) filter (where (props->>'p')::int <= 10), 'high', count(*) filter (where (props->>'p')::int >= 90),
        'extreme', (select coalesce(jsonb_agg(jsonb_build_object('n', e.props->>'n', 'q', e.props->>'q', 'p', e.props->>'p', 'x', ST_X(e.geom), 'y', ST_Y(e.geom))), '[]')
                    from (select * from core.map_point g2 where g2.layer = 'gauges' and g2.geom && env order by abs((g2.props->>'p')::int - 50) desc limit 4) e))
      from core.map_point g where g.layer = 'gauges' and g.geom && env),
    'counts', (select coalesce(jsonb_object_agg(layer, n), '{}') from (select layer, count(*) n from core.map_point where layer in ('bridges','reservoirs','beaches') and geom && env group by 1) z),
    'parks', (select coalesce(jsonb_agg(name), '[]') from core.boundary where kind = 'national_park' and geom && env),
    'towns', (select coalesce(jsonb_agg(name order by area_km2 desc), '[]') from (select name, area_km2 from core.boundary where kind = 'urban_area' and label_pt && env order by area_km2 desc limit 6) t)
  ) into r;
  perform set_config('response.headers', '[{"Cache-Control":"public, max-age=30"}]', true);
  return r;
end $$;
grant execute on function api.area_summary(double precision, double precision, double precision, double precision) to anon, authenticated;
