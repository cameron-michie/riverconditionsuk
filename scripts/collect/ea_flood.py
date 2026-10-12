"""EA flood-monitoring API: stations, measures (latest), warnings/areas, 7 days of 15-min archive readings."""
import datetime as dt, gzip
from lib import *
S = "ea_flood"; B = "https://environment.data.gov.uk/flood-monitoring"
for ep in ("stations", "measures", "floods", "floodAreas"):
    r = get(f"{B}/id/{ep}", params={"_limit": 20000} if ep != "stations" else {"_limit": 20000})
    save(S, f"{ep}.json", r.content, r.url); log(S, f"{ep} {len(r.content)//1024}KB")
for ep in ("stations?parameter=rainfall", "stations?parameter=flow", "stations?parameter=temperature"):
    pass
today = dt.date.today()
for i in range(1, 8):
    d = today - dt.timedelta(days=i)
    u = f"{B}/archive/readings-{d}.csv"
    r = get(u)
    if r.status_code == 200:
        save(S, f"archive/readings-{d}.csv.gz", gzip.compress(r.content), u); log(S, f"archive {d} {len(r.content)//1_000_000}MB")
    else:
        log(S, f"archive {d} -> {r.status_code}")
