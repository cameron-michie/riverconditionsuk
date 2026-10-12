"""Flood likelihood: FFC 5-day Flood Guidance Statement (v1 public API; v3 needs a free key) + ONS county/unitary boundaries + active EA warning polygons."""
import httpx, json
from lib import *
S = "flood"
FGS = "https://api.ffc-environment-agency.fgs.metoffice.gov.uk/api/public/v1/statements/latest"
r = get(FGS); st = r.json()["statement"]; save(S, "fgs_latest.json", r.content, FGS, "OGL-3.0 (Flood Forecasting Centre)")
c = httpx.get(st["detailed_csv_url"], timeout=60, headers={"User-Agent": UA}); save(S, f"fgs_detailed_{st['id']}.csv", c.content, st["detailed_csv_url"], "OGL-3.0 (Flood Forecasting Centre)")
log(S, f"FGS {st['id']} issued {st['issued_at']}, csv {len(c.content)//1024} KB")
u = "https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services/Counties_and_Unitary_Authorities_December_2024_Boundaries_UK_BGC/FeatureServer/0"
f, m = arcgis_all(u, page=100); save(S, "ons_ctyua_2024.geojson", {"type": "FeatureCollection", "features": f}, u, "OGL-3.0 (ONS)"); log(S, f"authorities {len(f)} {[x['name'] for x in m['fields']][:8]}")
fl = getj("https://environment.data.gov.uk/flood-monitoring/id/floods")["items"]; polys = {}
for w in fl:
    a = w["floodArea"]
    try: polys[a["notation"]] = get(a["polygon"]).json()
    except Exception as e: log(S, f"polygon {a['notation']} failed {e}")
save(S, "active_warnings.json", {"warnings": fl, "polygons": polys}, "https://environment.data.gov.uk/flood-monitoring/id/floods", "OGL-3.0"); log(S, f"active warnings {len(fl)}")
