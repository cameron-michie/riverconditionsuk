-- Wye Alliance and Usk CaSTCo citizen-science weekly readings, straight from their public Epicollect5 projects.
-- Licence is not stated on the projects: stored as 'unknown' until the Wye & Usk Foundation confirms terms and attribution (see docs/ACCESS.md).
insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, notes) values
  ('epicollect_wye', 'Wye Alliance citizen science (Epicollect5)', 'Wye Alliance (CPRE, Friends of the Upper Wye, Friends of the Lower Wye, Wye Salmon Association)', 'GBR', 'rest_api',
   'https://five.epicollect.net/project/wye-alliance-citizen-science', (select id from ingest.licence where slug = 'unknown'), 'citizen_science', 'P1D', 'P1D', 'active',
   'Public project, no key. Export API limited to 5 requests/minute, 500 entries per page. Weekly volunteer sampling at ~340 sites since 2021.'),
  ('epicollect_usk', 'Usk CaSTCo citizen science (Epicollect5)', 'Wye and Usk Foundation, Gwent Wildlife Trust, Save the River Usk', 'GBR', 'rest_api',
   'https://five.epicollect.net/project/usk-castco-citizen-science', (select id from ingest.licence where slug = 'unknown'), 'citizen_science', 'P1D', 'P1D', 'active',
   'Public project, no key. Same API limits as the Wye project.')
on conflict (slug) do nothing;
alter table core.survey drop constraint survey_kind_check;
alter table core.survey add constraint survey_kind_check check (kind in ('big_river_watch','riverfly_rmi','riverfly_urban','riverfly_extended_wq','riverfly_extended_silt_flow','morph','water_rangers','citizen_weekly','other'));
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('epicollect', 'MIN_GAP=24 ../../.venv/bin/python -W ignore ../etl/epicollect.py', 60, 'epicollect_wye', 3600, 360)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
