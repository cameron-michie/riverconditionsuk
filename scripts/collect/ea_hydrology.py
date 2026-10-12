"""EA Hydrology API: all stations + 1y of daily mean flow and daily rainfall totals."""
import concurrent.futures as cf, datetime as dt
from lib import *
S = "ea_hydrology"; H = "https://environment.data.gov.uk/hydrology"
r = get(f"{H}/id/stations.json", params={"_limit": 20000}, timeout=300)
items = r.json()["items"]; save(S, "stations.json", r.content, r.url); log(S, f"stations {len(items)}")
want = []
for s in items:
    for m in s.get("measures", []):
        mid = m["@id"].rsplit("/", 1)[-1]
        if m.get("period") == 86400 and ((m["parameter"] == "flow" and "-m-86400-" in mid) or (m["parameter"] == "rainfall" and "-t-86400-" in mid)):
            want.append(mid)
log(S, f"measures wanted {len(want)}")
start = (dt.date.today() - dt.timedelta(days=365)).isoformat()
def one(mid):
    import os
    if os.path.exists(os.path.join(ROOT, S, 'readings', mid + '.json')): return mid, None
    try:
        out, off = [], 0
        while True:
            it = getj(f"{H}/id/measures/{mid}/readings.json", params=({"mineq-date": start, "_limit": 1000} | ({"_offset": off} if off else {}))).get("items", []); out += it
            if len(it) < 1000: break
            off += 1000
        return mid, out
    except Exception as e:
        log(S, f"fail {mid} {e}"); return mid, None
n = 0
with cf.ThreadPoolExecutor(3) as ex:
    for mid, out in ex.map(one, want):
        if out is not None:
            save(S, f"readings/{mid}.json", out, f"{H}/id/measures/{mid}/readings"); n += 1
log(S, f"readings saved {n}/{len(want)}")
