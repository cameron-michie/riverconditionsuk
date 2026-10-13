"""Compute entrypoint. pg_cron in the cam-rivers database calls POST /run with {job, run_id} (via ops.dispatch_job); this runs that job's command from ops.etl_job in the
background and records the result in cam-rivers (ops.etl_run / ops.etl_job), exactly as the laptop scheduler did. Secrets arrive as environment variables."""
import hmac, json, os, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
for src, dst in (("RIVERS_DB_URL", "DATABASE_URL"), ("RIVERS_SUPABASE_URL", "STORAGE_URL"), ("RIVERS_SERVICE_KEY", "STORAGE_KEY")):
    if os.environ.get(src): os.environ[dst] = os.environ[src]
if os.environ.get("RIVERS_SUPABASE_URL") and os.environ.get("RIVERS_ETL_TOKEN"):                 # EA hydrology / linked-data APIs block this IP: fetch them through the eaproxy Edge Function
    os.environ["EA_PROXY_URL"] = os.environ["RIVERS_SUPABASE_URL"].rstrip("/") + "/functions/v1/eaproxy"; os.environ["EA_PROXY_TOKEN"] = os.environ["RIVERS_ETL_TOKEN"]
sys.path[:0] = ["/app/scripts/etl", "/app/scripts/load", "/app/scripts"]
import scheduler                                                  # noqa: E402  (reads DATABASE_URL when imported)
TOKEN = os.environ.get("RIVERS_ETL_TOKEN", ""); running = {}

def run(job, rid):
    running[rid] = job
    try: scheduler.worker(job, rid)
    except Exception:
        import traceback; print(f"worker {job} run {rid} crashed:", traceback.format_exc(), file=sys.stderr, flush=True)
    finally: running.pop(rid, None)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        out = json.dumps(body).encode(); self.send_response(code); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(out)
    def do_GET(self): self.send(200, {"ok": True, "running": sorted(running.values())})
    def do_POST(self):
        if not TOKEN or not hmac.compare_digest(self.headers.get("X-ETL-Token", ""), TOKEN): return self.send(401, {"error": "unauthorised"})
        try: n = int(self.headers.get("content-length") or 0); b = json.loads(self.rfile.read(n) or b"{}"); job, rid = str(b["job"]), int(b["run_id"])
        except Exception: return self.send(400, {"error": "need {job, run_id}"})
        threading.Thread(target=run, args=(job, rid), daemon=True).start(); self.send(202, {"accepted": job, "run_id": rid})

ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("PORT", 8080))), H).serve_forever()
