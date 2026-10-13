-- NRW flood APIs (keys in .env). Flood Risk Forecast covers the day of issue plus two days. Both responses are empty when nothing is happening in Wales, and NRW publishes no schema,
-- so scripts/etl/nrw_flood.py saves every non-empty response raw (data/raw/nrw_flood/) until the real field names have been seen.
insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, notes) values
  ('nrw_flood_warnings', 'NRW live flood warnings and alerts', 'Natural Resources Wales', 'WLS', 'rest_api', 'https://api.naturalresources.wales/floodwarnings/v3/all', (select id from ingest.licence where slug = 'ogl3'), 'regulator_assessment', 'PT15M', 'PT30M', 'active', 'Needs subscription key (free). GeoJSON FeatureCollection.'),
  ('nrw_flood_risk', 'NRW flood risk forecast (3 days)', 'Natural Resources Wales', 'WLS', 'rest_api', 'https://api.naturalresources.wales/floodforecast/v2/areasatrisk', (select id from ingest.licence where slug = 'ogl3'), 'regulator_assessment', 'P1D', 'PT6H', 'active', 'Needs subscription key (free). Day of issue plus two days. Empty list when no area is at risk.')
on conflict (slug) do nothing;
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('nrw_flood', '../../.venv/bin/python -W ignore ../etl/nrw_flood.py', 15, 'nrw_flood_warnings', 300, 60)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug;
