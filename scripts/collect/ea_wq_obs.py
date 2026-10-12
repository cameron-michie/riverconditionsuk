"""EA WQ Archive observations (CSV, 2500/page) for priority river determinands, month x region, 2023-01 -> now."""
import datetime as dt, gzip, os, httpx, calendar
from lib import *
S = "ea_wq"; B = "https://environment.data.gov.uk/water-quality"
DET = "0180,0348,0117,0118,0116,0111,0119,9901,9924,0082,0085,0061,0076,0077,0068,0135,0729"
REGIONS = ["AN", "MD", "NE", "NW", "SO", "SW", "TH"]
today = dt.date.today()
months = []
y, m = 2023, 1
while (y, m) <= (today.year, today.month):
    months.append((y, m)); m += 1
    if m == 13: y, m = y + 1, 1
months.reverse()   # newest first so recent data lands early
import lib
for (y, m) in months:
    d0 = dt.date(y, m, 1); d1 = dt.date(y, m, calendar.monthrange(y, m)[1])
    for reg in REGIONS:
        name = f"obs/{y}-{m:02d}_{reg}.csv.gz"
        if os.path.exists(os.path.join(ROOT, S, name)): continue
        rows, skip, header = [], 0, None
        while True:
            q = {"determinand": DET, "dateFrom": d0.isoformat(), "dateTo": d1.isoformat(), "limit": 2500, "skip": skip, "region": reg, "samplingPointType": "F6"}
            for t in range(6):
                lib._throttle(B)
                try:
                    r = httpx.post(f"{B}/data/observation", params=q, headers={"Accept": "text/csv", "User-Agent": UA}, timeout=60)
                except httpx.TransportError:
                    time.sleep(min(60, 4 * 2 ** t)); r = None; continue
                if r.status_code == 200: break
                time.sleep(min(60, 4 * 2 ** t))
            else:
                log(S, f"obs {y}-{m} {reg} failed {getattr(r, 'status_code', None)}"); header = None; break
            lines = r.text.strip().split("\n")
            if header is None: header = lines[0]
            body = lines[1:]; rows += body
            if len(body) < 2500: break
            skip += 2500
        if header is not None:
            save(S, name, gzip.compress(("\n".join([header] + rows) + "\n").encode()), f"{B}/data/observation", "OGL-3.0", f"{reg} {y}-{m:02d}")
            log(S, f"obs {y}-{m:02d} {reg}: {len(rows)}")
