"""Storm overflows: 10 water-company near-real-time ArcGIS feeds + EA annual returns + ID lookup."""
import json, datetime as dt
from lib import *
S = "sewage"
FEEDS = {
 "anglian":"https://services3.arcgis.com/VCOY1atHWVcDlvlJ/arcgis/rest/services/stream_service_outfall_locations_view/FeatureServer/0",
 "northumbrian":"https://services-eu1.arcgis.com/MSNNjkZ51iVh8yBj/arcgis/rest/services/Northumbrian_Water_Storm_Overflow_Activity_2_view/FeatureServer/0",
 "severn_trent":"https://services1.arcgis.com/NO7lTIlnxRMMG9Gw/arcgis/rest/services/Severn_Trent_Water_Storm_Overflow_Activity/FeatureServer/0",
 "south_west":"https://services-eu1.arcgis.com/OMdMOtfhATJPcHe3/arcgis/rest/services/NEH_outlets_PROD/FeatureServer/0",
 "thames":"https://services2.arcgis.com/g6o32ZDQ33GpCIu3/arcgis/rest/services/Thames_Water_Storm_Overflow_Activity_(Production)_view/FeatureServer/0",
 "united_utilities":"https://services5.arcgis.com/5eoLvR0f8HKb7HWP/arcgis/rest/services/United_Utilities_Storm_Overflow_Activity/FeatureServer/0",
 "wessex":"https://services.arcgis.com/3SZ6e0uCvPROr4mS/arcgis/rest/services/Wessex_Water_Storm_Overflow_Activity/FeatureServer/0",
 "yorkshire":"https://services-eu1.arcgis.com/1WqkK5cDKUbF0CkH/arcgis/rest/services/Yorkshire_Water_Storm_Overflow_Activity/FeatureServer/0",
}
ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%MZ")
for k, u in FEEDS.items():
    try:
        f, m = arcgis_all(u)
        save(S, f"nsoh/{k}_{ts}.geojson", {"type":"FeatureCollection","features":f}, u, "OGL/company-open", "near-real-time status snapshot")
        log(S, f"{k}: {len(f)}")
    except Exception as e:
        log(S, f"{k} FAILED {e}")
EA = "https://services1.arcgis.com/JZM7qJpmv7vJ0Hzx/arcgis/rest/services/edm_annual_returns_all_years_public/FeatureServer/0"
f, m = arcgis_all(EA, page=1000)
save(S, "ea_edm_annual_returns_all_years.geojson", {"type":"FeatureCollection","features":f}, EA, "OGL-3.0", "all years, all strings")
log(S, f"ea annual: {len(f)}")
L = "https://services-eu1.arcgis.com/XxS6FebPX29TRGDJ/arcgis/rest/services/Storm_Overflow_ID_Lookup/FeatureServer/0"
f, m = arcgis_all(L, geometry=False)
save(S, "id_lookup.json", f, L, "OGL", "old->new unique id")
log(S, f"lookup: {len(f)}")
