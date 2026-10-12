"""EA WQ Archive: final-effluent monitoring at water-company sewage works (type SA), 2025 onward. Operator self-monitoring compliance data."""
import datetime as dt, gzip, os, httpx, calendar, time
from lib import *
import lib
S = "ea_wq"; B = "https://environment.data.gov.uk/water-quality"
DET = "0111,0085,0135,0348,0180,0076,0061,0119"       # ammonia, BOD, suspended solids, total P, ortho-P, temperature, pH, un-ionised ammonia
REGIONS = ["AN", "MD", "NE", "NW", "SO", "SW", "TH"]
today = dt.date.today(); months = []; y, m = 2025, 1
while (y, m) <= (today.year, today.month):
    months.append((y, m)); m += 1
    if m == 13: y, m = y + 1, 1
for (y, m) in reversed(months):
    d0 = dt.date(y, m, 1); d1 = dt.date(y, m, calendar.monthrange(y, m)[1])
    for reg in REGIONS:
        name = f"effluent/{y}-{m:02d}_{reg}.csv.gz"
        if os.path.exists(os.path.join(ROOT, S, name)): continue
        rows, skip, header = [], 0, None
        while True:
            q = {"determinand": DET, "dateFrom": d0.isoformat(), "dateTo": d1.isoformat(), "limit": 2500, "skip": skip, "region": reg, "samplingPointType": "SA"}
            r = None
            for t in range(6):
                lib._throttle(B)
                try: r = httpx.post(f"{B}/data/observation", params=q, headers={"Accept": "text/csv", "User-Agent": UA}, timeout=60)
                except httpx.TransportError: time.sleep(min(60, 4 * 2 ** t)); r = None; continue
                if r.status_code == 204: r = httpx.Response(200, text=""); break      # no data published for this window
                if r.status_code == 200: break
                time.sleep(min(60, 4 * 2 ** t))
            else:
                log(S, f"effluent {y}-{m} {reg} failed"); header = None; break
            if not r.text.strip(): header = header or ""; break
            lines = r.text.strip().split("\n"); header = header or lines[0]; rows += lines[1:]
            if len(lines) - 1 < 2500: break
            skip += 2500
        if header:
            save(S, name, gzip.compress(("\n".join([header] + rows) + "\n").encode()), f"{B}/data/observation", "OGL-3.0", f"SA {reg} {y}-{m:02d}"); log(S, f"effluent {y}-{m:02d} {reg}: {len(rows)}")
