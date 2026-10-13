"""SEPA KiWIS beyond flow: river stage (15-minute) and rainfall (hourly totals), last 6 hours, for every Scottish station that reports them.
Series are created on first sight. Stage is relative to each gauge's own zero (qualifier 'stage'), so it is not comparable across sites."""
import os, sys, urllib.parse
import common, lib
from common import upsert_obs
from db import connect, source_id, start_run, finish_run

KI = "https://timeseries.sepa.org.uk/KiWIS/KiWIS?service=kisters&type=queryServices&datasource=0&format=json"
JOBS = [  # (parametertype_name, ts_name, ref.parameter code, aggregation, interval_s, unit, qualifier)
    ("S", "15minute", "water_level", "instant", 900, "m", "stage"),
    ("Precip", "Hour.Total", "rainfall", "sum", 3600, "mm", "hourly_total"),
]
q = lambda **kw: KI + "&" + urllib.parse.urlencode(kw)
with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "sepa_kiwis"); run = start_run(cur, "sepa_kiwis", "sepa_extra")
    cur.execute("select value, site_id from geo.site_key where scheme = 'sepa:station_no'"); SITE = dict(cur.fetchall())
    cur.execute("select code, id from ref.parameter"); PID = dict(cur.fetchall())
    cur.execute("select source_series_key, id from live.series where source_id = %s", (S,)); SER = dict(cur.fetchall())
    seen = written = made = 0
    for ptype, tsname, code, agg, interval, unit, qual in JOBS:
        lst = lib.getj(q(request="getTimeseriesList", parametertype_name=ptype, ts_name=tsname, returnfields="ts_id,station_no", rows=3000), timeout=120)[1:]
        ids = []
        for ts, no in lst:
            site = SITE.get(no)
            if site is None: continue
            if ts not in SER:
                cur.execute("""insert into live.series (site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, qualifier, evidence_class)
                               values (%s, %s, %s, %s, %s, %s, %s, %s, 'official_monitoring') on conflict do nothing returning id""", (site, PID[code], S, ts, agg, interval, unit, qual))
                x = cur.fetchone()
                if x is None: continue
                SER[ts] = x[0]; made += 1
            ids.append(ts)
        rows = []
        for i in range(0, len(ids), 80):
            try: out = lib.getj(q(request="getTimeseriesValues", ts_id=",".join(ids[i:i + 80]), period="PT6H", returnfields="Timestamp,Value"), timeout=120)
            except Exception as e: print(ptype, "batch failed", str(e)[:80]); continue
            for o in out:
                for t, v in o.get("data", []):
                    if isinstance(v, (int, float)) and v >= 0 and (code != "rainfall" or v < 200): rows.append((SER[str(o["ts_id"])], t.replace("Z", "+00"), v, "unchecked", None))
        a, b = upsert_obs(cur, rows, update=False); seen += a; written += b
        print(f"{ptype}/{tsname}: {len(ids)} series, {a} readings, {b} new", flush=True)
    finish_run(cur, run, read=seen, written=written); conn.commit()
    print(f"sepa extra: {seen} readings, {written} new, {made} new series")
