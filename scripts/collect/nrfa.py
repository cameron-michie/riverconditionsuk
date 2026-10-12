"""NRFA: all station metadata (incl. catchment descriptors / land cover) + 3y daily mean flow."""
import concurrent.futures as cf, datetime as dt
from lib import *
S = "nrfa"; B = "https://nrfaapps.ceh.ac.uk/nrfa/ws"
r = get(f"{B}/station-info", params={"station": "*", "format": "json-object", "fields": "all"}, timeout=300)
st = r.json()["data"]; save(S, "station_info.json", r.content, r.url, "OGL (UKCEH)"); log(S, f"stations {len(st)}")
start = (dt.date.today() - dt.timedelta(days=3*365)).isoformat()
def one(s):
    try:
        r = get(f"{B}/time-series", params={"station": s["id"], "data-type": "gdf", "format": "json-object", "start": start})
        return s["id"], r.content
    except Exception as e:
        return s["id"], None
n = 0
with cf.ThreadPoolExecutor(6) as ex:
    for sid, c in ex.map(one, st):
        if c: save(S, f"gdf/{sid}.json", c, f"{B}/time-series?station={sid}&data-type=gdf", "OGL (UKCEH)"); n += 1
log(S, f"gdf saved {n}")
