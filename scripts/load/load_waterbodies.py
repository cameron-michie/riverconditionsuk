"""Waterbodies (England), with the latest WFD classification per element (folded from cycles 1-4), reasons for not achieving good (latest cycle)
and SEPARATE source apportionment, all kept on geo.waterbody."""
import json, re, time, gzip, os
import pandas as pd
from db import *
t0 = time.time()
def slug(s): return re.sub(r"[^a-z0-9]+", "_", str(s).lower()).strip("_")
CAT = {"River": "river", "Canal": "canal", "Surface Water Transfer": "surface_water_transfer", "SurfaceWaterTransfer": "surface_water_transfer", "Lake": "lake", "River Canal and Surface Water Transfer": "river"}
C4 = {  # cycle-4 layer column -> element code
 "overall_water_body_class": "overall", "ecological_class": "ecological", "chemical_class": "chemical", "fish_class": "fish",
 "invertebrates_class": "invertebrates", "macrophytes_phytobenthos_combined_class": "macrophytes_phytobenthos",
 "ammonia_phys_chem_class": "ammonia", "dissolved_oxygen_class": "dissolved_oxygen", "ph_class": "ph", "phosphate_class": "phosphate",
 "temperature_class": "temperature", "priority_hazardous_substances": "priority_hazardous", "priority_substances_class": "priority_substances",
 "other_pollutants_class": "other_pollutants", "specific_pollutants_class": "specific_pollutants", "hydrological_regime_class": "hydrological_regime",
 "morphology_class": "morphology"}
def load(name): return json.load(open(os.path.join(RAW, "castco", name + ".geojson")))["features"]

with connect() as conn, conn.cursor() as cur:
    src_c4 = source_id(cur, "castco_wfd_c4"); src_cde = source_id(cur, "ea_cde_classification"); src_rn = source_id(cur, "ea_cde_rnag"); src_sep = source_id(cur, "castco_separate")
    run = start_run(cur, "castco_wfd_c4", "load_waterbodies.py")
    lines = load("wfd_c4_river_wb_lines__0"); polys = load("wfd_c4_river_wb_catchments__0")
    VM = wfd_status_map(cur)

    # ── waterbodies (+ geometry via staging for single-statement transform); catchment names go on the row
    wb = {}
    for f in lines:
        p = f["properties"]; wb.setdefault(p["water_body_id"], {"p": p})["line"] = f["geometry"]
    for f in polys:
        p = f["properties"]; wb.setdefault(p["water_body_id"], {"p": p})["poly"] = f["geometry"]
    cur.execute("create temp table stg_wb (code text, name text, category text, designation text, country text, rbd text, man text, opc text, line text, poly text) on commit drop")
    def wbrows():
        for code, d in wb.items():
            p = d["p"]
            yield (code, p.get("water_body_name"), CAT.get(p.get("water_body_type"), "river"), p.get("water_body_hmd"), "ENG" if p.get("country") in (None, "England") else ("WLS" if p.get("country") == "Wales" else None),
                   p.get("river_basin_district"), p.get("management_catchment"), p.get("operational_catchment"),
                   json.dumps(d["line"]) if d.get("line") else None, json.dumps(d["poly"]) if d.get("poly") else None)
    copy_rows(cur, "stg_wb", ["code", "name", "category", "designation", "country", "rbd", "man", "opc", "line", "poly"], wbrows())
    cur.execute("""insert into geo.waterbody (wb_code, name, category, designation, country, rbd, management_catchment, operational_catchment, line_geom, catchment_geom, area_km2, length_km, source_id, ids)
        select s.code, s.name, s.category, s.designation, s.country, s.rbd, s.man, s.opc,
               case when s.line is not null then ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(s.line), 4326)) end,
               case when s.poly is not null then ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(s.poly), 4326)), 3)) end,
               case when s.poly is not null then ST_Area(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(s.poly), 4326), 27700)) / 1e6 end,
               case when s.line is not null then ST_Length(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(s.line), 4326), 27700)) / 1e3 end,
               %s, jsonb_build_object('wfd_id', s.code)
        from stg_wb s
        on conflict (wb_code) do nothing""", (src_c4,))
    cur.execute("select wb_code, id from geo.waterbody"); WB = dict(cur.fetchall()); print("waterbodies", len(WB), round(time.time() - t0, 1), "s")

    # ── classification, cycle 4 (2025) from layer columns
    cur.execute("create temp table stg_cl (wb_code text, cycle smallint, year smallint, element text, status_native text, certainty text) on commit drop")
    rows = []
    for f in lines:
        p = f["properties"]
        if p["water_body_id"] not in WB: continue
        yr = int(p.get("classification_year") or 2025)
        for col, el in C4.items():
            v = p.get(col)
            if v in (None, "", " "): continue
            cert = p.get("eco_certainty_less_than_good") if el == "ecological" else (p.get("chem_certainty_less_than_good") if el == "chemical" else None)
            rows.append((p["water_body_id"], 4, yr, el, v, cert))
    copy_rows(cur, "stg_cl", ["wb_code", "cycle", "year", "element", "status_native", "certainty"], rows); print("c4 rows", len(rows))

    # ── earlier cycles from the CDE CSV (cycles 1-3): only to know each element's previous status
    EL = term_native(cur, "wfd_element")
    new_el = {}
    rows = []
    for ch in pd.read_csv(os.path.join(RAW, "wfd_england_classifications.csv"), dtype=str, chunksize=200000,
                          usecols=["Water Body ID", "Water Body Type", "Year", "Status", "Cycle", "Classification Level", "Classification Item", "Certainty", "Confidence"]):
        ch = ch[ch["Water Body ID"].isin(WB.keys())]
        for wid, yr, st, cy, lvl, item, ce, co in ch[["Water Body ID", "Year", "Status", "Cycle", "Classification Level", "Classification Item", "Certainty", "Confidence"]].itertuples(index=False):
            if not isinstance(item, str) or not isinstance(st, str): continue
            code = EL.get(item.lower())
            if code is None:
                code = "x_" + slug(item)[:60]; EL[item.lower()] = code
                new_el[code] = (item, lvl)
            rows.append((wid, int(cy), int(yr), code, st, ce if isinstance(ce, str) else None))
    print("cde rows", len(rows), "new elements", len(new_el), round(time.time() - t0, 1), "s")
    for code, (item, lvl) in new_el.items():
        level = "specific_pollutant" if lvl in ("Component", "Sub Element") else "other"
        cur.execute("insert into ref.term (domain, code, label, native, attrs) values ('wfd_element', %s, %s, %s, jsonb_build_object('level', %s::text)) on conflict do nothing", (code, item, [item], level))
    copy_rows(cur, "stg_cl", ["wb_code", "cycle", "year", "element", "status_native", "certainty"], rows)
    cur.execute("create temp table stg_vm (native text, canonical text) on commit drop")
    copy_rows(cur, "stg_vm", ["native", "canonical"], [(k, v[0]) for k, v in VM.items()])
    cur.execute("""create temp table stg_cls on commit drop as
        select w.id waterbody_id, s.cycle, s.year, s.element, coalesce(v.canonical, 'not_assessed') status, s.certainty
        from stg_cl s join geo.waterbody w on w.wb_code = s.wb_code left join stg_vm v on v.native = lower(s.status_native)""")
    print("waterbodies classified", fold_classes(cur, "stg_cls"), round(time.time() - t0, 1), "s")

    # ── reasons for not achieving good (RNAG / RFD), latest cycle per waterbody
    SEC = term_native(cur, "pressure_sector")
    rn = pd.read_csv(gzip.open(os.path.join(RAW, "cde", "england_rnags.csv.gz")), dtype=str)
    rn = rn[rn["Water Body ID"].isin(WB.keys())]
    cur.execute("create temp table stg_rn (wb_code text, cycle smallint, element text, sector text, sector_native text, activity text, certainty text) on commit drop")
    rows = []
    for _, r in rn.iterrows():
        el = EL.get(str(r.get("Classification Element", "")).lower())
        rows.append((r["Water Body ID"], int(r["Cycle"]) if str(r.get("Cycle")).isdigit() else None, el,
                     SEC.get(str(r.get("Category", "")).lower(), "other"), r.get("Category"), r.get("Activity"), r.get("Category Certainty")))
    copy_rows(cur, "stg_rn", ["wb_code", "cycle", "element", "sector", "sector_native", "activity", "certainty"], rows)
    cur.execute("""update geo.waterbody w set reasons = x.r from (
          select s.wb_code, jsonb_agg(jsonb_strip_nulls(jsonb_build_object('sector', s.sector, 'sector_native', s.sector_native, 'activity', s.activity, 'element', s.element, 'certainty', s.certainty))
                                      order by s.sector, s.activity) r
          from stg_rn s where s.cycle is not distinct from (select max(s2.cycle) from stg_rn s2 where s2.wb_code = s.wb_code) group by s.wb_code) x
        where x.wb_code = w.wb_code""")
    print("waterbodies with reasons", cur.rowcount)

    # ── SEPARATE apportionment (modelled)
    SECT = {"am": "agriculture", "be": "bank_erosion", "ur": "urban_diffuse", "sw": "sewage_works", "st": "storm_tanks", "sc": "septic_tanks", "so": "combined_sewer_overflows", "dd": "direct_deposition"}
    cur.execute("create temp table stg_ap (wb_code text, pollutant text, sector text, load numeric, share numeric) on commit drop")
    rows = []
    for fname, pol, pre in (("sources_phosphorus__0", "phosphorus", "P"), ("sources_nitrogen__0", "nitrogen", "N"), ("sources_sediment__0", "sediment", "S")):
        for f in load(fname):
            p = f["properties"]; wid = p.get("wb_id")
            if wid not in WB: continue
            for k, sec in SECT.items():
                lt, sp = p.get(f"{pre}_{k}_L_t"), p.get(f"{pre}_{k}_L_p")
                if lt is None and sp is None: continue
                rows.append((wid, pol, sec, lt, sp))
    copy_rows(cur, "stg_ap", ["wb_code", "pollutant", "sector", "load", "share"], rows)
    cur.execute("""update geo.waterbody w set apportionment = x.a from (
          select wb_code, jsonb_agg(jsonb_build_object('pollutant', pollutant, 'sector', sector, 'share_pct', least(100, greatest(0, share)), 'load_t_yr', load) order by pollutant, share desc nulls last) a
          from (select distinct on (wb_code, pollutant, sector) * from stg_ap) s group by wb_code) x
        where x.wb_code = w.wb_code""")
    print("waterbodies with apportionment", cur.rowcount)
    finish_run(cur, run, written=len(WB)); conn.commit()
print("done", round(time.time() - t0, 1), "s")
