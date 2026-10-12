"""NRFA catchment daily rainfall (CEH-GEAR, catchment average) for every station with a flow record, 2015 -> end of published data. Training signal for the flow model."""
import concurrent.futures as cf, os
from lib import *
S = "nrfa"; B = "https://nrfaapps.ceh.ac.uk/nrfa/ws"
ids = sorted(f[:-5] for f in os.listdir(os.path.join(ROOT, S, "gdf")))
def one(i):
    if os.path.exists(os.path.join(ROOT, S, "cdr", f"{i}.json")): return i, None
    try: return i, get(f"{B}/time-series", params={"station": i, "data-type": "cdr", "format": "json-object", "start": "2015-01-01"}).content
    except Exception: return i, None
n = 0
with cf.ThreadPoolExecutor(6) as ex:
    for i, c in ex.map(one, ids):
        if c: save(S, f"cdr/{i}.json", c, f"{B}/time-series?station={i}&data-type=cdr", "OGL (UKCEH)"); n += 1
log(S, f"cdr saved {n} of {len(ids)}")
