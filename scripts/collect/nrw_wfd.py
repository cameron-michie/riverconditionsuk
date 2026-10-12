"""Wales WFD cycle-3 classified river waterbody catchments (DataMapWales WFS, paged)."""
import httpx
from lib import *
W = "https://datamap.gov.wales/geoserver/ows"; T = "geonode:nrw_wfd_river_waterbody_catchments_c3_baseline_classification"
feats, start = [], 0
while True:
    d = getj(W, params={"service": "WFS", "version": "2.0.0", "request": "GetFeature", "typeNames": T, "outputFormat": "application/json", "srsName": "EPSG:4326", "count": 100, "startIndex": start, "sortBy": "objectid"}, timeout=300)
    f = d.get("features", []); feats += f; log("wfd", f"wales c3 {len(feats)}")
    if len(f) < 100: break
    start += 100
save("wfd", "wales_c3_baseline_classification.geojson", {"type": "FeatureCollection", "features": feats}, W, "OGL (NRW)")
