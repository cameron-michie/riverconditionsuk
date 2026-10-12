-- Welsh Water's own live overflow layer (the National Hub covers England only), SEPA stage and rainfall, and the slow NRFA top-up.
insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, notes) values
  ('dcww_overflow_live', 'Welsh Water storm overflow activity (live)', 'Dwr Cymru Welsh Water', 'WLS', 'arcgis_feature_service',
   'https://services3.arcgis.com/KLNF7YxtENPLYVey/arcgis/rest/services/Spill_Prod__External/FeatureServer/0', (select id from ingest.licence where slug = 'company-open'), 'company_reported', 'PT15M', 'PT1H', 'active',
   '2,362 assets with status, last start/stop and 7-day duration. Found inside the company web map; no published licence, treated like the other company feeds.')
on conflict (slug) do nothing;
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('dcww_overflows', '../../.venv/bin/python -W ignore ../etl/dcww_overflows.py', 5, 'dcww_overflow_live', 300, 30),
  ('sepa_extra',     '../../.venv/bin/python -W ignore ../etl/sepa_extra.py',     15, 'sepa_kiwis',         600, 60),
  ('nrfa_recent',    '../../.venv/bin/python -W ignore ../etl/nrfa_recent.py',    43200, 'nrfa',          3600, 100000)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('bathing_recent', '../../.venv/bin/python -W ignore ../etl/bathing_recent.py', 360, 'ea_bathing', 600, 2880)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug;
