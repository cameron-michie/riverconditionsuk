-- launchd's PATH finds a Python without httpx/psycopg: run every job with the project's venv interpreter (which sees the same system packages).
update ops.etl_job set command = regexp_replace(command, '(^|&& |; )python3 ', '\1../../.venv/bin/python ', 'g')
where name <> 'eo_worker' and command ~ 'python3 ';
