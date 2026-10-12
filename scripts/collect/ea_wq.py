"""EA Water Quality Archive (new 2026 API): codelists + all sampling points + observations for priority determinands at river points."""
import concurrent.futures as cf, datetime as dt, json
from lib import *
S = "ea_wq"; B = "https://environment.data.gov.uk/water-quality"
J = {"Accept": "application/ld+json"}; G = {"Accept": "application/geo+json"}
for cl in ("determinand", "unit", "sample-material", "sampling-point-status", "sampling-point-type", "sampling-purpose"):
    out, skip = [], 0
    while True:
        m = getj(f"{B}/codelist/{cl}", params={"limit": 250, "skip": skip}, headers=J).get("member", []); out += m
        if len(m) < 250: break
        skip += 250
    save(S, f"codelist_{cl}.json", out, f"{B}/codelist/{cl}"); log(S, f"codelist {cl}: {len(out)}")
# sampling points, all types
tot = getj(f"{B}/sampling-point", params={"limit": 1}, headers=G)["totalItems"]; log(S, f"sampling points total {tot}")
def page(skip):
    return getj(f"{B}/sampling-point", params={"limit": 250, "skip": skip}, headers=G)["member"]
pts = []
with cf.ThreadPoolExecutor(2) as ex:
    for m in ex.map(page, range(0, tot, 250)): pts += m
save(S, "sampling_points.geojson", {"type": "FeatureCollection", "features": pts}, f"{B}/sampling-point"); log(S, f"points saved {len(pts)}")
