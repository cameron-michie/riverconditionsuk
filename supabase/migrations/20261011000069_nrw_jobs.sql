-- NRW in the scheduler: open telemetry (15 min) and the flood poller are already registered. Add the daily history gap-fill (only stale series, ~0 calls on a normal day).
-- The one-off year backfill is run by hand (scripts/etl/nrw_historical.py) and refuses to run twice.
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('nrw_gapfill', '../../.venv/bin/python -W ignore ../etl/nrw_historical.py --gaps', 1440, 'nrw_river_levels', 3600, 2880)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
