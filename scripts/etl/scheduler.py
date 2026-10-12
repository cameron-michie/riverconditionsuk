"""Run every due job in ops.etl_job. Meant to be called once a minute by an external scheduler (launchd, cron, a container). Not part of the frontend."""
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); LOAD = os.path.join(HERE, "..", "load")
sys.path[:0] = [LOAD, os.path.join(HERE, "..")]
from db import connect
with connect() as conn, conn.cursor() as cur:
    cur.execute("""update ops.etl_job set running_since = null where running_since < now() - interval '2 hours'""")
    cur.execute("""select name, command from ops.etl_job where enabled and running_since is null
                   and (last_started_at is null or last_started_at + make_interval(mins => interval_minutes) <= now()) order by name""")
    due = cur.fetchall(); conn.commit()
    for name, command in due:
        cur.execute("update ops.etl_job set running_since = now(), last_started_at = now() where name = %s", (name,))
        cur.execute("insert into ops.etl_run (job) values (%s) returning id", (name,)); rid = cur.fetchone()[0]; conn.commit()
        p = subprocess.run(command, shell=True, cwd=LOAD, capture_output=True, text=True, env=dict(os.environ, PYTHONPATH=os.path.join(HERE, "..")))
        st = "ok" if p.returncode == 0 else "failed"
        cur.execute("update ops.etl_run set finished_at = now(), status = %s, output = %s where id = %s", (st, (p.stdout + p.stderr)[-4000:], rid))
        cur.execute("update ops.etl_job set running_since = null, last_finished_at = now(), last_status = %s where name = %s", (st, name)); conn.commit()
        print(name, st)
