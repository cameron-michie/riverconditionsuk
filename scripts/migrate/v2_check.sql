-- Post-upgrade checks: table inventory, sizes, the satellite-monitoring objects, and that the api answers.
\pset footer off
select n.nspname schema, count(*) filter (where c.relkind in ('r','p') and not c.relispartition) tables, count(*) filter (where c.relkind = 'v') views,
       pg_size_pretty(sum(pg_total_relation_size(c.oid)) filter (where c.relkind in ('r','p','m'))) size
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('ref','geo','live','ops','api','core') group by 1 order by 1;

select c.oid::regclass "table", c.reltuples::bigint approx_rows, pg_size_pretty(pg_total_relation_size(c.oid)) size
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('ref','geo','live','ops') and c.relkind in ('r','p') order by pg_total_relation_size(c.oid) desc;

-- satellite monitoring (must match the pre-upgrade counts)
select 'core.reach' t, count(*) from core.reach union all select 'core.scene', count(*) from core.scene
union all select 'core.eo_observation', count(*) from core.eo_observation union all select 'core.eo_event', count(*) from core.eo_event
union all select 'core.eo_matchup', count(*) from core.eo_matchup union all select 'core.eo_calibration', count(*) from core.eo_calibration
union all select 'core.geo_observation', count(*) from core.geo_observation;
select p.oid::regprocedure fn from pg_proc p where p.proname in ('build_reaches','mark_observable','ensure_eo_partitions','eo_chlorophyll');
select conrelid::regclass, confrelid::regclass, conname from pg_constraint where conrelid = 'core.reach'::regclass and contype = 'f';
select name, enabled from ops.etl_job where name = 'eo_worker';
select pg_database_size(current_database()) / 1024 / 1024 as db_mb;
