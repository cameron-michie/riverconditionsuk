-- Weather on the map: two layers in a new 'weather' group, and one API call that returns what to show at a given time.
-- Rain = radar for the past and now, ECMWF IFS for the future. Pressure = IFS isobars (nearest 3-hour step).
alter table core.map_layer drop constraint map_layer_geom_kind_check, drop constraint map_layer_grp_check;
alter table core.map_layer add constraint map_layer_geom_kind_check check (geom_kind in ('line','polygon','point','raster'));
alter table core.map_layer add constraint map_layer_grp_check check (grp in ('base','overlay','sewage','points','weather'));
insert into core.map_layer (code, label, grp, geom_kind, min_zoom, default_on, sort, note) values
  ('rain',     'rain',     'weather', 'raster', 0, false, 5, 'wx.frame via api.weather(); radar for now, IFS for the forecast'),
  ('pressure', 'pressure', 'weather', 'line',   0, false, 6, 'wx.contour via api.weather(); isobars every 2 hPa')
on conflict (code) do nothing;

create or replace function api.weather(p_at timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path = wx, core, public, pg_temp as $$
declare at timestamptz := coalesce(p_at, now()); fr record; pr record; out jsonb := '{}';
begin
  -- rain: radar up to now, forecast after. Fall back to whichever exists.
  select * into fr from (
    select 'radar' src, f.* from wx.frame f where f.product = 'radar_rain' and at <= now() + interval '20 minutes'
    union all
    select 'forecast', f.* from wx.frame f where f.product = 'ifs_rain' and at > now() + interval '20 minutes'
  ) x order by abs(extract(epoch from x.valid_at - at)) limit 1;
  if fr.id is null then
    select 'forecast' src, f.* into fr from wx.frame f where f.product in ('ifs_rain', 'radar_rain') order by abs(extract(epoch from f.valid_at - at)) limit 1;
  end if;
  if fr.id is not null then
    out := out || jsonb_build_object('rain', jsonb_build_object('path', fr.storage_path, 'bbox', fr.bbox, 'valid_at', fr.valid_at, 'issued_at', fr.issued_at, 'kind', fr.src,
             'source', case fr.src when 'radar' then 'Met Office radar' else 'ECMWF forecast' end, 'legend', fr.legend));
  end if;
  -- pressure: newest run, nearest step
  select product, issued_at, valid_at into pr from wx.contour where product = 'ifs_mslp' and issued_at = (select max(issued_at) from wx.contour where product = 'ifs_mslp')
    group by product, issued_at, valid_at order by abs(extract(epoch from valid_at - at)) limit 1;
  if pr.valid_at is not null then
    out := out || jsonb_build_object('pressure', jsonb_build_object('valid_at', pr.valid_at, 'issued_at', pr.issued_at, 'source', 'ECMWF forecast',
             'lines', (select jsonb_agg(jsonb_build_object('l', c.level, 'g', ST_AsGeoJSON(c.geom, 3)::jsonb->'coordinates') order by c.level)
                       from wx.contour c where c.product = pr.product and c.issued_at = pr.issued_at and c.valid_at = pr.valid_at)));
  end if;
  -- times the slider can step through: the last radar frames, then forecast steps
  out := out || jsonb_build_object('times', (select coalesce(jsonb_agg(jsonb_build_object('at', valid_at, 'kind', k) order by valid_at), '[]') from (
      select valid_at, 'radar' k from wx.frame where product = 'radar_rain'
      union all select valid_at, 'forecast' from wx.frame where product = 'ifs_rain' and valid_at > (select coalesce(max(valid_at), now()) from wx.frame where product = 'radar_rain')) t));
  return out;
end $$;
grant execute on function api.weather(timestamptz) to anon, authenticated;
