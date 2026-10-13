"""Run scheduled ETL jobs once, in the foreground, against a database, and report each one's exit status and tail of output.
    DATABASE_URL=... python run_jobs.py [job ...]      (default: every enabled job except the slow ones listed in SKIP)
Uses the commands in ops.etl_job exactly as the scheduler would (cwd scripts/load)."""
import os, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__)); LOAD = os.path.join(HERE, "..", "load")
sys.path[:0] = [LOAD]
from db import connect
SKIP = {"normals", "archive", "eo_worker"}
with connect() as conn, conn.cursor() as cur:
    cur.execute("select name, command, timeout_s from ops.etl_job where enabled order by name"); JOBS = cur.fetchall()
want = sys.argv[1:] or [j[0] for j in JOBS if j[0] not in SKIP]
bad = 0
for name, command, timeout_s in JOBS:
    if name not in want: continue
    t0 = time.time()
    try:
        p = subprocess.run(command, shell=True, cwd=LOAD, capture_output=True, text=True, timeout=timeout_s, env=dict(os.environ, PYTHONPATH=os.path.join(HERE, "..")))
        ok, out = p.returncode == 0, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        ok, out = False, "timeout"
    bad += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name:20s} {time.time() - t0:6.1f}s  {out[-600:] if not ok else out.splitlines()[-1][:160] if out else ''}", flush=True)
print("all jobs ran" if not bad else f"{bad} failed")
sys.exit(1 if bad else 0)
