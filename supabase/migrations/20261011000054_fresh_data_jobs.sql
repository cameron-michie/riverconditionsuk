-- Fresher data: the live job runs every 5 minutes (sewage feeds update that often); daily hydrology and lab chemistry refresh on rolling windows.
update ops.etl_job set interval_minutes = 5, max_lag_minutes = 20 where name = 'live';
insert into ops.etl_job (name, command, interval_minutes, source_slug, timeout_s, max_lag_minutes) values
  ('ea_hydrology_daily', 'python3 -W ignore ../etl/ea_hydrology_daily.py 14', 360, 'ea_hydrology', 900, 1500),
  ('ea_wq_recent', 'python3 -W ignore ../collect/ea_wq_recent.py 45 && WQ_GLOB=''inc_*.csv.gz'' INCREMENTAL=1 python3 -W ignore load_series.py wq', 720, 'ea_wq_archive', 1800, 2880)
on conflict (name) do update set command = excluded.command, interval_minutes = excluded.interval_minutes, source_slug = excluded.source_slug, timeout_s = excluded.timeout_s, max_lag_minutes = excluded.max_lag_minutes;
