"""EA Water Quality Archive: samples from the last N days (default 45) for the priority river determinands, all regions -> obs/inc_*.csv.gz.
The EA adds samples within two working days and revises older ones, so a rolling window is refetched every run (loader upserts by value)."""
import datetime as dt, glob, gzip, os, sys, httpx, time
import lib
from lib import *
S = "ea_wq"; B = "https://environment.data.gov.uk/water-quality"
DET = "0180,0348,0117,0118,0116,0111,0119,9901,9924,0082,0085,0061,0076,0077,0068,0135,0729"
REGIONS = ["AN", "MD", "NE", "NW", "SO", "SW", "TH"]
days = int(sys.argv[1]) if len(sys.argv) > 1 else 45
d1 = dt.date.today(); d0 = d1 - dt.timedelta(days=days)
for old in glob.glob(os.path.join(ROOT, S, "obs", "inc_*.csv.gz")): os.remove(old)
total = 0
for reg in REGIONS:
    rows, skip, header, ok = [], 0, None, True
    while True:
        q = {"determinand": DET, "dateFrom": d0.isoformat(), "dateTo": d1.isoformat(), "limit": 2500, "skip": skip, "region": reg, "samplingPointType": "F6"}
        for t in range(6):
            lib._throttle(B)
            try: r = httpx.post(f"{B}/data/observation", params=q, headers={"Accept": "text/csv", "User-Agent": UA}, timeout=90)
            except httpx.TransportError: time.sleep(min(60, 4 * 2 ** t)); r = None; continue
            if r.status_code in (200, 204): break
            time.sleep(min(60, 4 * 2 ** t))
        else: log(S, f"recent {reg} failed"); ok = False; break
        if r.status_code == 204: break
        lines = r.text.strip().split("\n"); header = header or lines[0]; body = lines[1:]; rows += body
        if len(body) < 2500: break
        skip += 2500
    if header and ok:
        save(S, f"obs/inc_{d1:%Y%m%d}_{reg}.csv.gz", gzip.compress(("\n".join([header] + rows) + "\n").encode()), f"{B}/data/observation", "OGL-3.0", f"{reg} {d0}..{d1}")
        total += len(rows); print(reg, len(rows), flush=True)
print("recent wq rows", total)
