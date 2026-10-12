"""More overflow feeds: Southern Water live, Scottish Water live, Rivers Trust annual E&W series, Hafren Dyfrdwy."""
import datetime as dt
from lib import *
S = "sewage"
ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%MZ")
LIVE = {
 "southern": "https://services-eu1.arcgis.com/6qJmARkS2dt2IjVA/arcgis/rest/services/SouthernWater_StormOverflowActivity_PROD_view/FeatureServer/0",
 "scottish_water_stream": "https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services/Scottish_Water_Storm_Overflow_Activity/FeatureServer/0",
 "scottish_water_sepa_live": "https://services-eu1.arcgis.com/jj6fR2HO7enbrICO/arcgis/rest/services/Scottish_Water_Overflows_live/FeatureServer/0",
}
for k, u in LIVE.items():
    try:
        f, m = arcgis_all(u); save(S, f"nsoh/{k}_{ts}.geojson", {"type": "FeatureCollection", "features": f}, u, "company-open", "near-real-time snapshot"); log(S, f"{k}: {len(f)}")
    except Exception as e: log(S, f"{k} FAILED {e}")
ANN = {
 "rt_edm_2025_ew": "https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services/Event_Duration_Monitoring_Storm_Overflows_2025/FeatureServer/0",
 "rt_edm_2024_ew": "https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services/Storm_Overflow_EDM_Annual_Returns_2024/FeatureServer/0",
 "hd_edm_2025": "https://services-eu1.arcgis.com/XxS6FebPX29TRGDJ/arcgis/rest/services/HD_EDM_2025_Final_File/FeatureServer/0",
}
for k, u in ANN.items():
    try:
        f, m = arcgis_all(u, page=1000); save(S, f"annual/{k}.geojson", {"type": "FeatureCollection", "features": f}, u, "OGL/Rivers Trust"); log(S, f"{k}: {len(f)}")
    except Exception as e: log(S, f"{k} FAILED {e}")
