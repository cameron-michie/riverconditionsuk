"""Run every due job in ops.etl_job. Called once a minute by launchd (or cron, or a container tick). Not part of the frontend.
Each tick only decides what is due and starts one detached worker per job, then returns at once, so a slow job (the NRFA top-up takes 18 minutes) can never
hold up a fast one: launchd will not start a new tick while the previous one is still running. A worker runs the job's command bounded by timeout_s and records the result.
  scheduler.py                         tick
  scheduler.py --worker <job> <run_id> run one job (started by the tick)"""
import os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); LOAD = os.path.join(HERE, "..", "load")
sys.path[:0] = [LOAD, os.path.join(HERE, "..")]
from db import connect

def retry(fn, what, tries=7):
    """the pooler can refuse a connection when many clients (other workloads share it) connect at once: back off and try again, and say so in the log."""
    for i in range(tries):
        try: return fn()
        except Exception as e:
            print(f"[{name_now()}] {what}: attempt {i + 1} failed: {str(e)[:200]}", file=sys.stderr, flush=True)
            if i == tries - 1: raise
            time.sleep(min(30, 2 ** i))
name_now = lambda: __import__("datetime").datetime.now().strftime("%H:%M:%S")

def worker(name, rid):
    """run one job. No database connection is held while the job runs (it may take minutes and the pooler closes idle ones); the result is written on a fresh connection."""
    def get_cmd():
        with connect() as conn, conn.cursor() as cur:
            cur.execute("select command, timeout_s from ops.etl_job where name = %s", (name,)); r = cur.fetchone(); conn.commit(); return r
    command, timeout_s = retry(get_cmd, f"{name} read command")
    print(f"[{name_now()}] {name} run {rid} start", flush=True)
    try:
        p = subprocess.run(command, shell=True, cwd=LOAD, capture_output=True, text=True, timeout=timeout_s, env=dict(os.environ, PYTHONPATH=os.path.join(HERE, "..")))
        st, out = ("ok" if p.returncode == 0 else "failed"), (p.stdout + p.stderr)[-4000:]
    except subprocess.TimeoutExpired as e:
        st, out = "timeout", ((e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")))[-2000:]
    def finish():
        with connect() as conn, conn.cursor() as cur:
            cur.execute("update ops.etl_run set finished_at = now(), status = %s, output = %s where id = %s", (st, out, rid))
            cur.execute("update ops.etl_job set running_since = null, last_finished_at = now(), last_status = %s where name = %s", (st, name)); conn.commit()
    retry(finish, f"{name} record result")
    print(f"[{name_now()}] {name} run {rid} {st}", flush=True)

def tick():
    with connect() as conn, conn.cursor() as cur:
        cur.execute("""update ops.etl_job set running_since = null where running_since < now() - make_interval(secs => greatest(timeout_s, 600) + 600)""")
        cur.execute("""select name from ops.etl_job where enabled and running_since is null
                       and (last_started_at is null or last_started_at + make_interval(mins => interval_minutes) <= now()) order by name""")
        due = [r[0] for r in cur.fetchall()]
        for name in due:
            cur.execute("update ops.etl_job set running_since = now(), last_started_at = now() where name = %s", (name,))
            cur.execute("insert into ops.etl_run (job) values (%s) returning id", (name,)); rid = cur.fetchone()[0]; conn.commit()
            subprocess.Popen([sys.executable, os.path.abspath(__file__), "--worker", name, str(rid)], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print("started", name, flush=True)

if __name__ == "__main__":
    if len(sys.argv) > 3 and sys.argv[1] == "--worker": worker(sys.argv[2], int(sys.argv[3]))
    else: tick()
