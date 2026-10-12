-- ea_wq_recent: the loader call follows an env assignment, so the previous pattern missed it.
update ops.etl_job set command = replace(command, 'python3 ', '../../.venv/bin/python ') where name <> 'eo_worker' and command like '%python3 %';
-- Daily hydrology is hot for 8 days (ops.retention_rule); refetch only 7 so archived days are not re-inserted.
update ops.etl_job set command = '../../.venv/bin/python -W ignore ../etl/ea_hydrology_daily.py 7' where name = 'ea_hydrology_daily';
