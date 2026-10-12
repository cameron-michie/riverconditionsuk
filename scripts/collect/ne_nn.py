"""Natural England nutrient-neutrality catchments (England)."""
from lib import *
u = "https://services.arcgis.com/JJzESW51TqeY9uat/arcgis/rest/services/Nutrient_Neutrality_Catchments_England/FeatureServer/0"
f, m = arcgis_all(u)
save("ne", "nutrient_neutrality_catchments.geojson", {"type": "FeatureCollection", "features": f}, u, "OGL-3.0 (Natural England)")
log("ne", f"nn catchments {len(f)}; fields {[x['name'] for x in m['fields']][:12]}")
