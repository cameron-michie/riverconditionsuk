-- NRW's telemetry API turned out to be open (scope measures.read.open, no key): latest reading for every Welsh river level and rain gauge, refreshed every 15 minutes.
update ingest.source set status = 'active', kind = 'rest_api', base_url = 'https://api.naturalresources.wales/telemetry/api/', licence_id = (select id from ingest.licence where slug = 'ogl3'),
  cadence = 'PT15M', expected_lag = 'PT30M', status_note = null,
  notes = 'Open, no key. /stations and /measures only: the latest value per measure, no history, so readings accumulate from the day we start polling. 241 level and 148 rainfall measures.'
where slug = 'nrw_river_levels';
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('nrw_telemetry', '../../.venv/bin/python -W ignore ../etl/nrw_telemetry.py', 15, 'nrw_river_levels', 300, 60)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
