-- Weather jobs. Commands run from scripts/load (see scripts/etl/scheduler.py). Both are idempotent.
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('wx_radar', '../../.venv/bin/python -W ignore ../etl/wx_radar.py 3', 15, 'metoffice_radar', 600, 45),
  ('wx_ifs',   '../../.venv/bin/python -W ignore ../etl/wx_ifs.py',    60, 'ecmwf_ifs',       1800, 960)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
