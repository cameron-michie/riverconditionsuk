"""EA bathing water in-season samples: the newest 1,000 (E. coli, intestinal enterococci), same parsing as load_misc.py. Samples arrive daily in the season (15 May - 30 Sep)."""
import common, lib
from common import upsert_obs
from db import connect, source_id, start_run, finish_run

D = "https://environment.data.gov.uk/doc/bathing-water-quality/in-season/sample.json"
v = lambda x: x.get("_value") if isinstance(x, dict) else x
first = lambda y: (y[0] if y else None) if isinstance(y, list) else y
def cens(q):
    n = (q or {}).get("countQualifierNotation"); return n if n in ("<", ">") else None
items = []
for page in range(2):
    items += lib.getj(D, params={"_pageSize": 500, "_page": page, "_sort": "-sampleDateTime"}, timeout=180)["result"]["items"]
with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "ea_bathing"); run = start_run(cur, "ea_bathing", "bathing_recent")
    cur.execute("select value, site_id from geo.site_key where scheme = 'eubwid'"); EU = dict(cur.fetchall())
    cur.execute("select source_series_key, id from live.series where source_id = %s", (S,)); SER = dict(cur.fetchall())
    import datetime as dt; from zoneinfo import ZoneInfo
    rows = []; skipped = 0
    for x in items:
        bw = x.get("bwq_bathingWater"); eu = bw.get("eubwidNotation") if isinstance(bw, dict) else (bw.rsplit("/", 1)[-1] if isinstance(bw, str) else None)
        at = ((x.get("sampleDateTime") or {}).get("inXSDDateTime") or {}).get("_value")
        if not at or eu not in EU: skipped += 1; continue
        t = dt.datetime.fromisoformat(at).replace(tzinfo=ZoneInfo("Europe/London")).astimezone(dt.timezone.utc)
        for par, cv, cq in (("ecoli", "escherichiaColiCount", "escherichiaColiQualifier"), ("enterococci", "intestinalEnterococciCount", "intestinalEnterococciQualifier")):
            n = first(x.get(cv)); q = cens(first(x.get(cq)))
            sid = SER.get(f"bwq:{eu}:{par}")
            if n is None or sid is None: continue
            rows.append((sid, t, None if q else float(n), "suspect" if "true" == str(v(x.get("discountable"))).lower() else "good", None, q, float(n) if q else None))
    a, b = upsert_obs(cur, rows, update=False)
    newest = max((r[1] for r in rows), default=None)
    finish_run(cur, run, read=a, written=b, rejected=skipped); conn.commit()
    print(f"bathing: {a} readings in the newest {len(items)} samples, {b} new, newest sample {newest}")
