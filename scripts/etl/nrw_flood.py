"""NRW live flood warnings (GeoJSON) and flood risk forecast (list of areas at risk). Records each poll in ingest.run and saves any non-empty response raw,
because the real field names are not published and both feeds are empty in quiet weather. Loading into core.flood_warning / core.flood_forecast follows once a real response is on disk."""
import datetime as dt, json, os, sys
import common, lib
from db import connect, source_id, start_run, finish_run

for line in open(os.path.join(lib.ROOT, "..", "..", ".env")):
    if "=" in line and not line.startswith("#"): k, v = line.strip().split("=", 1); os.environ.setdefault(k, v)
B = "https://api.naturalresources.wales/"
FEEDS = [("nrw_flood_warnings", "floodwarnings/v3/all", "NRW_FLOOD_WARNINGS_KEY", lambda j: len(j.get("features", []))),
         ("nrw_flood_risk", "floodforecast/v2/areasatrisk", "NRW_FLOOD_RISK_KEY", lambda j: len(j))]
now = dt.datetime.now(dt.timezone.utc); out = []
with connect() as conn, conn.cursor() as cur:
    for slug, path, keyvar, count in FEEDS:
        run = start_run(cur, slug, "nrw_flood")
        try:
            r = lib.get(B + path, headers={"Ocp-Apim-Subscription-Key": os.environ[keyvar]}, timeout=60); j = r.json(); n = count(j)
            if n:
                d = os.path.join(lib.ROOT, "nrw_flood"); os.makedirs(d, exist_ok=True)
                open(os.path.join(d, f"{slug}_{now:%Y%m%dT%H%M}.json"), "wb").write(r.content)
            finish_run(cur, run, read=n, written=0); out.append(f"{slug}: {n} items")
        except Exception as e:
            finish_run(cur, run, status="failed", error=str(e)[:300]); out.append(f"{slug}: FAILED {str(e)[:80]}")
    conn.commit()
print("; ".join(out))
