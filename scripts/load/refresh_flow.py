"""Latest measured flow from every open gauge feed that refresh_live.py does not cover: EA Hydrology (15-minute, ~1,100 stations) and SEPA KiWIS (Scotland, ~320). Creates the 15-minute series on first sight."""
import datetime as dt, os, sys, time, urllib.parse
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")]
import lib
from db import *
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "etl")); import common
t0 = time.time()
HY = "https://environment.data.gov.uk/hydrology/data/readings.json"
KI = "https://timeseries.sepa.org.uk/KiWIS/KiWIS?service=kisters&type=queryServices&datasource=0&format=json"

def put(cur, rows):
    common.upsert_obs(cur, [(sid, at, v, "unchecked") for sid, at, v in rows], update=False)

with connect() as conn, conn.cursor() as cur:
    cur.execute("select id from ref.parameter where code = 'river_flow'"); P = cur.fetchone()[0]
    # ── EA Hydrology: one call, latest 15-minute flow per station
    S = source_id(cur, "ea_hydrology")
    items = lib.getj(HY + "?observedProperty=waterFlow&periodName=15min&latest&_limit=100000", timeout=300)["items"]
    cur.execute("select value, site_id from geo.site_key where scheme = 'ea_hydro:guid'"); SITE = dict(cur.fetchall())
    cur.execute("select source_series_key, id from live.series where source_id = %s", (S,)); SER = dict(cur.fetchall())
    rows, made = [], 0
    for r in items:
        mid = r["measure"]["@id"].rsplit("/", 1)[-1]; v = r.get("value")
        if not isinstance(v, (int, float)) or not mid.endswith("-flow-i-900-m3s-qualified"): continue
        key = "hydro:" + mid; sid = SER.get(key)
        if sid is None:
            site = SITE.get(mid[:36])
            if site is None: continue
            cur.execute("""insert into live.series (site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, qualifier, evidence_class)
                           values (%s, %s, %s, %s, 'instant', 900, 'm3_s', 'qualified', 'official_monitoring') on conflict do nothing returning id""", (site, P, S, key))
            x = cur.fetchone(); sid = x[0] if x else None; made += 1
            if sid is None: continue
            SER[key] = sid
        rows.append((sid, r["dateTime"] + "+00", v))
    put(cur, rows); print("ea hydrology", len(rows), "readings,", made, "new series", round(time.time() - t0, 1), "s")
    # ── SEPA KiWIS: 15-minute flow
    S = source_id(cur, "sepa_kiwis")
    lst = lib.getj(KI + "&" + urllib.parse.urlencode({"request": "getTimeseriesList", "parametertype_name": "Q", "ts_name": "15minute", "returnfields": "ts_id,station_no", "rows": 2000}), timeout=120)[1:]
    cur.execute("select value, site_id from geo.site_key where scheme = 'sepa:station_no'"); SITE = dict(cur.fetchall())
    cur.execute("select source_series_key, id from live.series where source_id = %s", (S,)); SER = dict(cur.fetchall())
    ids, made = [], 0
    for ts, no in lst:
        site = SITE.get(no)
        if site is None: continue
        if ts not in SER:
            cur.execute("""insert into live.series (site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, evidence_class)
                           values (%s, %s, %s, %s, 'instant', 900, 'm3_s', 'official_monitoring') on conflict do nothing returning id""", (site, P, S, ts))
            x = cur.fetchone()
            if x is None: continue
            SER[ts] = x[0]; made += 1
        ids.append(ts)
    rows = []
    for i in range(0, len(ids), 80):
        try: out = lib.getj(KI + "&" + urllib.parse.urlencode({"request": "getTimeseriesValues", "ts_id": ",".join(ids[i:i + 80]), "period": "PT6H", "returnfields": "Timestamp,Value"}), timeout=120)
        except Exception as e: print("sepa batch failed", str(e)[:80]); continue
        for o in out:
            for t, v in o.get("data", []):
                if isinstance(v, (int, float)) and v >= 0: rows.append((SER[str(o["ts_id"])], t.replace("Z", "+00"), v))
    put(cur, rows); print("sepa", len(rows), "readings from", len(ids), "series,", made, "new series", round(time.time() - t0, 1), "s")
    conn.commit()
