"""EA Hydrology: daily mean flow and daily rainfall for every station, last N days (default 14), in two calls. Quality flags are revised by the EA
over the following days, so this rewrites changed values. Usage: ea_hydrology_daily.py [days]"""
import datetime as dt, sys
import common, lib
from common import upsert_obs
from db import connect, source_id, start_run, finish_run

days = int(sys.argv[1]) if len(sys.argv) > 1 else 14
H = "https://environment.data.gov.uk/hydrology/data/readings.json"
QM = {"good": "good", "estimated": "estimated", "suspect": "suspect", "unchecked": "unchecked", "missing": "missing"}
since = (dt.date.today() - dt.timedelta(days=days)).isoformat()
with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "ea_hydrology"); run = start_run(cur, "ea_hydrology", "ea_hydrology_daily", {"days": days})
    cur.execute("select source_series_key, id from live.series where source_id = %s and interval_s = 86400", (S,)); SER = dict(cur.fetchall())
    seen = written = unknown = 0
    for prop in ("waterFlow", "rainfall"):
        items = lib.getj(f"{H}?observedProperty={prop}&periodName=daily&mineq-date={since}&_limit=200000", timeout=300)["items"]
        rows = []
        for r in items:
            sid = SER.get("hydro:" + r["measure"]["@id"].rsplit("/", 1)[-1])
            if sid is None: unknown += 1; continue
            try: v = float(r["value"]) if r.get("value") is not None else None
            except (TypeError, ValueError): v = None
            vd, inv, mis = (float(r.get(x) or 0) for x in ("valid", "invalid", "missing")); comp = vd / (vd + inv + mis) if vd + inv + mis > 0 else None
            rows.append((sid, r["dateTime"] + "+00", v, QM.get(str(r.get("quality", "")).lower(), "unchecked") if v is not None else "missing", comp))
        a, b = upsert_obs(cur, rows); seen += a; written += b; print(f"{prop}: {a} readings, {b} new or revised", flush=True)
    cur.execute("select live.flag_implausible(now() - make_interval(days => %s))", (days + 1,))
    finish_run(cur, run, read=seen, written=written, rejected=unknown); conn.commit()
    print(f"hydrology daily: {seen} read, {written} written, {unknown} on measures we do not track")
