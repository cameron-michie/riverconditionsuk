"""Overlay boundaries: ONS built-up areas + major towns/cities, national parks for England, Wales, Scotland."""
from lib import *
S = "boundaries"
LAYERS = {
 "bua_2022_gb": "https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services/BUA_2022_GB/FeatureServer/0",
 "major_towns_cities_2015": "https://services1.arcgis.com/ESMARspQHYMw9BZ9/arcgis/rest/services/Major_Towns_and_Cities_December_2015_Boundaries/FeatureServer/0",
 "np_england": "https://services.arcgis.com/JJzESW51TqeY9uat/arcgis/rest/services/National_Parks_England/FeatureServer/0",
 "np_wales": "https://services.arcgis.com/hQoYDJEEJMaPw8Sy/arcgis/rest/services/National_Parks/FeatureServer/0",
 "np_scotland": "https://maps.data.gov.scot/arcgis/rest/services/NationalParks/MapServer/0",
}
for k, u in LAYERS.items():
    try:
        f, m = arcgis_all(u, page=500)
        save(S, f"{k}.geojson", {"type": "FeatureCollection", "features": f}, u, "OGL-3.0 / OS-derived (check item)", m.get("name", ""))
        log(S, f"{k}: {len(f)} fields={[x['name'] for x in m['fields']][:14]}")
    except Exception as e:
        log(S, f"{k} FAILED {e}")
