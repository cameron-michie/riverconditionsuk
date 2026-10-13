"""Boundaries -> geo.area (kinds country, national_park, urban_area, city): Natural Earth country outlines, national parks, ONS built-up areas, major towns and cities."""
import json, os, time
from db import *
t0 = time.time()
KINDS = ("country", "national_park", "urban_area", "city")
def feats(p): return json.load(open(os.path.join(RAW, p)))["features"]
with connect() as conn, conn.cursor() as cur:
    cur.execute("""insert into ref.source (slug, name, publisher, country, kind, base_url, licence, licence_name, evidence_class, cadence, status)
                   values ('ons_boundaries','ONS built-up areas, major towns and cities; national park boundaries','ONS / Natural England / NRW / Scottish Government','GB','arcgis_feature_service',
                           'https://geoportal.statistics.gov.uk','ogl3','Open Government Licence v3.0','official_monitoring','P1Y','active') on conflict (slug) do nothing""")
    cur.execute("""insert into ref.source (slug, name, publisher, country, kind, base_url, licence, licence_name, licence_url, attribution, allows_redistribution, allows_commercial, evidence_class, cadence, status)
                   values ('osm_poi','OpenStreetMap named bridges, reservoirs and beaches','OpenStreetMap contributors','GB','rest_api','https://overpass-api.de',
                           'odbl','Open Database Licence 1.0','https://opendatacommons.org/licenses/odbl/1-0/','Contains data (c) OpenStreetMap contributors, ODbL.',true,true,'citizen_science','P1M','active')
                   on conflict (slug) do nothing""")
    src = source_id(cur, "ons_boundaries")
    cur.execute("delete from geo.area where kind = any(%s)", (list(KINDS),))
    cur.execute("create temp table stg_b (kind text, code text, name text, alt text, g text, rank int, attrs text) on commit drop")
    rows = []
    for f in feats("basemap/ne_10m_admin_0_map_subunits.geojson"):
        p = f["properties"]
        if p.get("SU_A3") in ("ENG", "SCT", "WLS", "NIR"): rows.append(("country", p["SU_A3"], p["SUBUNIT"], None, json.dumps(f["geometry"]), 1, "{}"))
    for f in feats("boundaries/np_england.geojson"): p = f["properties"]; rows.append(("national_park", "E:" + str(p.get("CODE") or p["OBJECTID"]), p["NAME"], None, json.dumps(f["geometry"]), 2, jdump({"country": "England", "designated": p.get("DESIG_DATE")})))
    for f in feats("boundaries/np_wales.geojson"): p = f["properties"]; rows.append(("national_park", "W:" + str(p["OBJECTID"]), p["NP_NAME"], None, json.dumps(f["geometry"]), 2, jdump({"country": "Wales"})))
    for f in feats("boundaries/np_scotland.geojson"): p = f["properties"]; rows.append(("national_park", "S:" + str(p.get("npcode") or p.get("objectid")), p["npname"], None, json.dumps(f["geometry"]), 2, jdump({"country": "Scotland"})))
    cities = {f["properties"]["TCITY15NM"].strip().lower() for f in feats("boundaries/major_towns_cities_2015.geojson")}
    for f in feats("boundaries/bua_2022_gb.geojson"):
        p = f["properties"]
        if not f.get("geometry"): continue
        nm = (p.get("BUA22NM") or "").strip()
        rows.append(("urban_area", p["BUA22CD"], nm, p.get("BUA22NMW"), json.dumps(f["geometry"]), 4, jdump({"is_major": nm.lower() in cities})))
    for f in feats("boundaries/major_towns_cities_2015.geojson"):
        if f.get("geometry"): p = f["properties"]; rows.append(("city", p["TCITY15CD"], p["TCITY15NM"].strip(), None, json.dumps(f["geometry"]), 2, "{}"))
    copy_rows(cur, "stg_b", ["kind", "code", "name", "alt", "g", "rank", "attrs"], rows)
    cur.execute("""insert into geo.area (kind, code, name, name_alt, geom, area_km2, rank, source_id, attrs)
        select kind, code, name, nullif(alt, ''), geom, ST_Area(ST_Transform(geom, 27700)) / 1e6, rank, %s, attrs::jsonb from (
          select s.*, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)), 3)) geom from stg_b s) q where not ST_IsEmpty(geom)""", (src,))
    # rank: large built-up areas count as towns worth showing earlier; major towns flagged by ONS
    cur.execute("""update geo.area set rank = case when attrs->>'is_major' = 'true' then 3 when area_km2 >= 20 then 3 else 4 end where kind = 'urban_area'""")
    cur.execute("""update geo.area set label_pt = ST_PointOnSurface(geom),
        geom_lo  = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, 0.012)), 3)),
        geom_mid = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, 0.0012)), 3)) where kind = any(%s)""", (list(KINDS),))
    cur.execute("update geo.area set name = regexp_replace(name, '^(.+) \\(\\1\\)$', '\\1') where kind = any(%s) and name ~ '^(.+) \\(\\1\\)$'", (list(KINDS),))   # ONS: "Swindon (Swindon)" -> "Swindon"
    cur.execute("analyze geo.area")
    cur.execute("select kind, count(*), round(avg(area_km2)::numeric,1), pg_size_pretty(sum(pg_column_size(geom))), pg_size_pretty(sum(pg_column_size(geom_lo))) from geo.area where kind = any(%s) group by 1 order by 1", (list(KINDS),)); print(cur.fetchall())
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
