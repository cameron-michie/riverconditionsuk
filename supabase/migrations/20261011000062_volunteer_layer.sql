-- Volunteer (citizen-science) sites on the map: Wye Alliance and Usk CaSTCo weekly readings. Additive: appends a branch to whatever core.map_point currently is.
insert into core.map_layer (code, label, grp, geom_kind, min_zoom, cluster_below, default_on, sort, max_features, note) values
  ('citizen', 'volunteers', 'points', 'point', 7, 10, false, 26, 3000, 'epicollect_wye / epicollect_usk survey sites; evidence class citizen_science')
on conflict (code) do nothing;

do $$
declare d text;
begin
  d := pg_get_viewdef('core.map_point'::regclass, true);
  if d not like '%''citizen''::text AS layer%' then
    execute 'create or replace view core.map_point as ' || rtrim(d, '; ' || chr(10)) || $v$
 union all
 select 'citizen'::text as layer, s.id, s.geom, false as hot,
        jsonb_strip_nulls(jsonb_build_object('n', s.name, 'org', s.attrs->>'organisation', 'at', v.last_visit, 'nv', v.visits, 'p', round(ph.value::numeric, 3), 'rv', r.slug, 'rn', r.name)) as props
   from core.site s
   join lateral (select max(sv.surveyed_at) last_visit, count(*) visits from core.survey sv where sv.site_id = s.id and sv.kind = 'citizen_weekly') v on true
   left join lateral (select l.value from core.series se join core.observation_latest l on l.series_id = se.id join ref.parameter p on p.id = se.parameter_id
                      where se.site_id = s.id and p.code = 'phosphorus_reactive' and se.evidence_class = 'citizen_science' order by l.observed_at desc limit 1) ph on true
   left join core.river r on r.id = s.river_id
  where s.kind = 'survey_site' and s.merged_into is null and v.visits > 0
$v$;
  end if;
end $$;

-- Panel for one volunteer site: latest value per measurement, a year of phosphate, and the visit record.
create or replace function api.volunteer_dossier(p_id bigint) returns jsonb
language sql stable security definer set search_path = core, ref, public, pg_temp as $$
  select jsonb_build_object(
    'site', jsonb_build_object('name', s.name, 'org', s.attrs->>'organisation', 'project', s.attrs->>'project', 'river', case when r.id is not null then jsonb_build_object('slug', r.slug, 'name', r.name) end,
                               'stretch', case when w.id is not null then jsonb_build_object('id', w.id, 'name', w.name) end),
    'visits', (select jsonb_build_object('n', count(*), 'first', min(surveyed_at), 'last', max(surveyed_at)) from core.survey where site_id = s.id and kind = 'citizen_weekly'),
    'latest', (select coalesce(jsonb_agg(jsonb_build_object('param', x.code, 'method', x.method, 'unit', x.unit_id, 'v', x.value, 'at', x.observed_at) order by x.code), '[]') from (
                 select distinct on (p.code, se.method) p.code, se.method, se.unit_id, l.value, l.observed_at
                 from core.series se join ref.parameter p on p.id = se.parameter_id join core.observation_latest l on l.series_id = se.id
                 where se.site_id = s.id and se.evidence_class = 'citizen_science' and l.observed_at > now() - interval '400 days' order by p.code, se.method, l.observed_at desc) x),
    'phosphate', (select coalesce(jsonb_agg(jsonb_build_array(round(extract(epoch from o.observed_at) * 1000), round(o.value::numeric, 3)) order by o.observed_at), '[]')
                  from core.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'phosphorus_reactive' join core.observation o on o.series_id = se.id
                  where se.site_id = s.id and se.evidence_class = 'citizen_science' and o.observed_at > now() - interval '365 days' and o.value is not null),
    'notes', (select answers from core.survey where site_id = s.id and kind = 'citizen_weekly' order by surveyed_at desc limit 1))
  from core.site s left join core.river r on r.id = s.river_id left join core.waterbody w on w.id = s.waterbody_id where s.id = p_id and s.kind = 'survey_site';
$$;
grant execute on function api.volunteer_dossier(bigint) to anon, authenticated;
