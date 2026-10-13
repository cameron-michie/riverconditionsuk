"""Always-on EO worker: watches STAC for new scenes, drains the pgmq `eo_jobs` queue, serves /health."""
from __future__ import annotations

import json
import logging
import signal
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import psycopg

from . import config, stac
from .scene_processor import process_scene

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("eo")

stop = threading.Event()
state = {"last_watch": 0.0, "last_job": 0.0, "scenes_done": 0}


class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        ok = time.time() - state["last_watch"] < config.WATCH_INTERVAL_S * 3 or state["last_watch"] == 0
        self.send_response(200 if ok else 503)
        self.end_headers()
        self.wfile.write(f"{state}".encode())

    def log_message(self, *a):
        pass


def watcher():
    while not stop.is_set():
        try:
            with psycopg.connect(config.DATABASE_URL) as conn:
                n = stac.watch_once(conn)
            state["last_watch"] = time.time()
            log.info("watcher: %d new scenes", n)
        except Exception:
            log.exception("watcher failed")
        stop.wait(config.WATCH_INTERVAL_S)


def run_run(conn, kind: str, fn):
    with conn.cursor() as cur:
        cur.execute("insert into ops.etl_run (job, started_at, status, output) values ('eo_worker', now(), 'running', %s) returning id", (kind,))
        run_id = cur.fetchone()[0]
    conn.commit()
    try:
        n = fn()
        status = "ok"
    except Exception:
        conn.rollback()
        log.exception("%s failed", kind)
        n, status = 0, "error"
    with conn.cursor() as cur:
        cur.execute("update ops.etl_run set finished_at=now(), status=%s, output=%s where id=%s",
                    (status, f"{kind}: {n} reaches scored", run_id))
    conn.commit()
    return status


def worker():
    with psycopg.connect(config.DATABASE_URL) as conn:
        while not stop.is_set():
            with conn.cursor() as cur:
                cur.execute("select msg_id, message from pgmq.read(%s, %s, 1)", (config.QUEUE, config.VISIBILITY_S))
                row = cur.fetchone()
            conn.commit()
            if not row:
                stop.wait(30)
                continue
            msg_id, msg = row
            sid = msg["scene_id"]
            status = run_run(conn, f"eo_scene:{sid}", lambda: process_scene(conn, sid))
            if status == "ok":
                with conn.cursor() as cur:
                    cur.execute("select pgmq.archive(%s, %s)", (config.QUEUE, msg_id))
                conn.commit()
                state["scenes_done"] += 1
                state["last_job"] = time.time()
            else:   # retry sooner than the long in-flight timeout
                with conn.cursor() as cur:
                    cur.execute("select pgmq.set_vt(%s, %s, 300)", (config.QUEUE, msg_id))
                conn.commit()


def bootstrap(conn):
    """Idempotent start-up: ensure the queue exists and every recent unscored scene has a job."""
    with conn.cursor() as cur:
        cur.execute("select pg_advisory_xact_lock(hashtext('eo_worker_bootstrap'))")   # serialise concurrent starts
        cur.execute("select 1 from pgmq.list_queues() where queue_name = %s", (config.QUEUE,))
        if not cur.fetchone():
            cur.execute("select pgmq.create(%s)", (config.QUEUE,))
        # single instance: a restart means whoever held in-flight messages is dead, so release them now
        cur.execute("update pgmq.q_eo_jobs set vt = now() where vt > now()")
        cur.execute(
            """select s.id from core.scene s
               where s.acquired_at > now() - make_interval(days => %s)
                 and not exists (select 1 from core.eo_observation o where o.scene_id = s.id)
                 and not exists (select 1 from pgmq.q_eo_jobs q where (q.message->>'scene_id')::bigint = s.id)
                 and not exists (select 1 from pgmq.a_eo_jobs a where (a.message->>'scene_id')::bigint = s.id)""",
            (config.BACKFILL_DAYS,),
        )
        for (sid,) in cur.fetchall():
            cur.execute("select pgmq.send(%s, %s::jsonb)", (config.QUEUE, json.dumps({"scene_id": sid})))
    conn.commit()


def main():
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: stop.set())
    srv = HTTPServer(("0.0.0.0", config.HEALTH_PORT), Health)
    threading.Thread(target=srv.serve_forever, daemon=True).start()   # up first so Compute sees a healthy port
    while not stop.is_set():
        try:
            with psycopg.connect(config.DATABASE_URL) as conn:
                bootstrap(conn)
            break
        except Exception:
            log.exception("bootstrap failed; retrying in 60s")
            stop.wait(60)
    threading.Thread(target=watcher, daemon=True).start()
    while not stop.is_set():
        try:
            worker()
        except Exception:
            log.exception("worker loop crashed; restarting in 30s")
            stop.wait(30)


if __name__ == "__main__":
    main()
