"""Run every due job in ops.etl_job. Meant to be called once a minute by an external scheduler (launchd, cron, a container). Not part of the frontend.
Due jobs run in parallel (one process each) so a slow job never delays a fast one; each is bounded by its timeout_s."""
import concurrent.futures as cf, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); LOAD = os.path.join(HERE, "..", "load")
sys.path[:0] = [LOAD, os.path.join(HERE, "..")]
from db import connect

def run(name, command, timeout_s, rid):
    try:
        p = subprocess.run(command, shell=True, cwd=LOAD, capture_output=True, text=True, timeout=timeout_s, env=dict(os.environ, PYTHONPATH=os.path.join(HERE, "..")))
        return name, rid, ("ok" if p.returncode == 0 else "failed"), (p.stdout + p.stderr)[-4000:]
    except subprocess.TimeoutExpired as e:
        return name, rid, "timeout", ((e.stdout or b"").decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or ""))[-2000:]

with connect() as conn, conn.cursor() as cur:
    cur.execute("""update ops.etl_job set running_since = null where running_since < now() - make_interval(secs => greatest(timeout_s, 600) + 600)""")
    cur.execute("""select name, command, timeout_s from ops.etl_job where enabled and running_since is null
                   and (last_started_at is null or last_started_at + make_interval(mins => interval_minutes) <= now()) order by name""")
    due = cur.fetchall(); conn.commit()
    work = []
    for name, command, timeout_s in due:
        cur.execute("update ops.etl_job set running_since = now(), last_started_at = now() where name = %s", (name,))
        cur.execute("insert into ops.etl_run (job) values (%s) returning id", (name,)); work.append((name, command, timeout_s, cur.fetchone()[0]))
    conn.commit()
    if work:
        with cf.ThreadPoolExecutor(max_workers=len(work)) as ex:
            for fut in cf.as_completed([ex.submit(run, *w) for w in work]):
                name, rid, st, out = fut.result()
                cur.execute("update ops.etl_run set finished_at = now(), status = %s, output = %s where id = %s", (st, out, rid))
                cur.execute("update ops.etl_job set running_since = null, last_finished_at = now(), last_status = %s where name = %s", (st, name)); conn.commit()
                print(name, st)
