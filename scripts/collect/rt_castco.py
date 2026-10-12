"""The Rivers Trust / CaSTCo ArcGIS org: citizen science + curated national WFD, apportionment and pressure layers."""
import re, concurrent.futures as cf
from lib import *
S = "castco"; R = "https://services3.arcgis.com/Bb8lfThdhugyc4G3/arcgis/rest/services"
SERVICES = {
 "big_river_watch": "The_Big_River_Watch_view",
 "riverfly": "Riverfly1",
 "riverfly_urban": "Urban_Riverfly_-_Public",
 "riverfly_ext_wq": "Extended_Riverfly_-_Water_Quality_-_Public",
 "riverfly_ext_silt_flow": "Extended_Riverfly_-_Silt_and_Flow_-_Public",
 "wfd_c4_river_wb_lines": "Simplified_WFD_River_Canal_and_SWT_Water_Bodies_2025_Cycle_4",
 "wfd_c4_river_wb_catchments": "Simplified_WFD_River_Water_Body_Catchments_Cycle_4_Classification_2025",
 "wfd_c3_wales_wb_catchments": "WFD_Cycle_3_WB_Catchment_Classifications_Wales",
 "sources_phosphorus": "Sources_of_Phosphorous_SEPARATE",
 "sources_nitrogen": "Sources_of_Nitrogen_SEPARATE",
 "sources_sediment": "Sources_of_Sediments_SEPARATE",
 "consented_sewage_discharges": "Sewage_discharges_Final_treated_effluent",
 "pollution_incidents_cat1_2": "Cat1_2_Env_Pollution_Incidents_identity",
 "pollution_incidents_cat3_4": "Category_3_and_4_Minor_Water_Environmental_Pollution_Incidents_summary_2020_to_2023",
 "river_obstacles": "River_Obstacles_view2",
 "eutrophication_woe_national": "Weight_of_Evidence_Eutrophication_National_Layer",
 "wqa_summary_statistics": "WIMs_summary_statistics",
 "ea_phosphate_standards": "EA_Phosphate_standards_for_Rivers_2022",
 "site_class_phosphate": "England_WFD_Site_Classifications_(Phosphate)",
 "site_class_ammonia": "England_WFD_Site_Classifications_(Ammonia)",
 "site_class_invertebrates": "England_site_classifications_(Invertebrates)",
 "site_class_fish": "England_WFD_Site_Classifications_(Fish)",
 "water_rangers": "WaterRangers_locations",
 "angling_trust_wqmn": "Angling_Trust_WQMN_update",
 "usk_citizen_science": "Usk_Citizen_Science_Data",
 "yorkshire_dales_monitoring": "Yorkshire_Dales_Rivers_Trust_Monitoring_Points",
 "caba_partnerships": "CaBA_Partnerships",
 "habitat_modification_england": "River_Habitat_Modification_Class_(2025)",
 "habitat_modification_wales": "River_Habitat_Modification_class_NRW",
}
def one(item):
    key, svc = item
    base = f"{R}/{svc}/FeatureServer"
    try:
        meta = getj(base, params={"f": "json"})
        layers = [l["id"] for l in meta.get("layers", [])] or [0]
        for lid in layers:
            u = f"{base}/{lid}"
            f, m = arcgis_all(u)
            save(S, f"{key}__{lid}.geojson", {"type": "FeatureCollection", "features": f, "properties": {"layer": m.get("name")}}, u, "OGL/CC (Rivers Trust CaSTCo; check item licence)", m.get("name", ""))
            log(S, f"{key}/{lid} '{m.get('name')}': {len(f)}")
    except Exception as e:
        log(S, f"{key} FAILED {e}")
with cf.ThreadPoolExecutor(3) as ex: list(ex.map(one, SERVICES.items()))
log(S, "done")
