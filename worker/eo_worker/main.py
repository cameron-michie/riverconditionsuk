"""Always-on EO worker: watches STAC for new scenes, drains the pgmq `eo_jobs` queue, serves /health."""
from __future__ import annotations

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
            # on error the message becomes visible again after VISIBILITY_S (retry)


def main():
    for s in (signal.SIGTERM, signal.SIGINT):
        signal.signal(s, lambda *_: stop.set())
    threading.Thread(target=watcher, daemon=True).start()
    srv = HTTPServer(("0.0.0.0", config.HEALTH_PORT), Health)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    worker()


if __name__ == "__main__":
    main()
