"""Wales: NRW DataMapWales WFS layers + CaSTCo Wales WFD cycle-3 catchments (retry)."""
from lib import *
S = "wfd"
W = "https://datamap.gov.wales/geoserver/ows"
for lyr in ("inspire-nrw:NRW_WFD_SURFACE_WATER_C2_LIVE", "inspire-nrw:NRW_WFD_OPERATIONAL_CATCHMENTS_C2", "inspire-nrw:NRW_MAIN_RIVERS",
            "geonode:nrw_water_quality_archive_stations", "inspire-nrw:NRW_PHOSPHORUS_SENSITIVE_SAC_FRESHWATER_CATCHMENTS",
            "geonode:nrw_bathing_waters", "inspire-nrw:NRW_SAC_PHOSPHORUS_COMPLIANCE_2017_19", "geonode:nrw_wye_failing_wb"):
    try:
        r = get(W, params={"service": "WFS", "version": "2.0.0", "request": "GetFeature", "typeNames": lyr, "outputFormat": "application/json", "srsName": "EPSG:4326"}, timeout=900)
        save(S, "wales_" + lyr.split(":")[1].lower() + ".geojson", r.content, r.url, "OGL (NRW)"); log(S, f"{lyr}: {len(r.content)//1024}KB")
    except Exception as e:
        log(S, f"{lyr} FAILED {e}")
u = "https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services/WFD_Cycle_3_WB_Catchment_Classifications_Wales/FeatureServer/0"
try:
    f, m = arcgis_all(u, page=200)
    save("castco", "wfd_c3_wales_wb_catchments__0.geojson", {"type": "FeatureCollection", "features": f}, u, "rt-castco"); log("castco", f"wales c3: {len(f)}")
except Exception as e:
    log("castco", f"wales c3 FAILED {e}")
