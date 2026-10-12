-- The flow forecast starts from the live flow signals, which change every 5 minutes (gauges report or drop out). It takes ~5 s, so run it on the same cadence.
update ops.etl_job set interval_minutes = 5, max_lag_minutes = 20 where name = 'flow_forecast';
