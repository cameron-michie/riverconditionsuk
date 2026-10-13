-- Drop the sites nothing uses: no series, no map layer, no survey, no gauge model. Run last in a full rebuild (after derive_works.sql).
-- The loaders create every site their sources list; most water-quality points and permits never carry data the app shows.
delete from geo.site s
where s.kind not in ('storm_overflow', 'bathing_water', 'survey_site', 'bridge')
  and not (s.kind = 'sewage_works' and s.attrs ? 'works')
  and not exists (select 1 from live.series se where se.site_id = s.id)
  and not exists (select 1 from geo.gauge_model g where g.site_id = s.id)
  and not exists (select 1 from live.survey v where v.site_id = s.id)
  and not exists (select 1 from geo.site w where w.kind = 'sewage_works' and (w.attrs->>'monitor_site_id')::bigint = s.id)
  and s.attrs->>'max_on_record' is null;
select kind, count(*) from geo.site group by 1 order by 2 desc;
