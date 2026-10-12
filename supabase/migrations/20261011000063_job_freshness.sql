-- One row per scheduled job: is it running, and is the data it produces within its allowed lag?
create or replace view ops.job_freshness as
select j.name, j.source_slug, j.enabled, j.interval_minutes, j.max_lag_minutes, j.last_status, j.last_started_at, j.last_finished_at,
       round(extract(epoch from now() - j.last_finished_at) / 60) as minutes_since_finish,
       coalesce(j.last_status in ('failed', 'timeout'), false) as failing,
       j.enabled and (j.last_finished_at is null or extract(epoch from now() - j.last_finished_at) / 60 > coalesce(j.max_lag_minutes, j.interval_minutes * 3)) as stale
from ops.etl_job j;
