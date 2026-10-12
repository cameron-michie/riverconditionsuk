"""Catchments, waterbodies, WFD classification (cycles 1-4), official RNAGs, SEPARATE apportionment."""
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
    # value map for statuses
    cur.execute("select native, canonical, rank from ref.value_map where domain='wfd_status'"); VM = {n.lower(): (c, r) for n, c, r in cur.fetchall()}

    # ── catchment hierarchy (no geometry yet; dissolved from waterbody polygons below)
    cats = {}
    for f in lines + polys:
        p = f["properties"]
        for kind, idk, nk in (("rbd", "rbd_id", "river_basin_district"), ("management", "mancat_id", "management_catchment"), ("operational", "opcat_id", "operational_catchment")):
            if p.get(idk) is not None: cats[(kind, str(p[idk]))] = (p.get(nk), p)
    cur.execute("create temp table stg_cat (kind text, code text, name text, parent_kind text, parent_code text) on commit drop")
    rows = []
    for (kind, code), (nm, p) in cats.items():
        pk, pc = (None, None)
        if kind == "management": pk, pc = "rbd", str(p.get("rbd_id"))
        if kind == "operational": pk, pc = "management", str(p.get("mancat_id"))
        rows.append((kind, code, nm or code, pk, pc))
    copy_rows(cur, "stg_cat", ["kind", "code", "name", "parent_kind", "parent_code"], rows)
    cur.execute("insert into core.catchment (kind, code, name, country, source_id) select kind, code, name, 'ENG', %s from stg_cat on conflict (kind, code) do nothing", (src_c4,))
    cur.execute("""update core.catchment c set parent_id = p.id from stg_cat s join core.catchment p on p.kind = s.parent_kind and p.code = s.parent_code
                   where c.kind = s.kind and c.code = s.code and s.parent_kind is not null""")
    cur.execute("select kind, code, id from core.catchment"); CID = {(k, c): i for k, c, i in cur.fetchall()}

    # ── waterbodies (+ geometry via staging for single-statement transform)
    wb = {}
    for f in lines:
        p = f["properties"]; wb.setdefault(p["water_body_id"], {"p": p})["line"] = f["geometry"]
    for f in polys:
        p = f["properties"]; wb.setdefault(p["water_body_id"], {"p": p})["poly"] = f["geometry"]
    cur.execute("create temp table stg_wb (code text, name text, category text, designation text, country text, rbd text, man text, opc text, line text, poly text, attrs text) on commit drop")
    def wbrows():
        for code, d in wb.items():
            p = d["p"]
            attrs = {k: p.get(k) for k in ("ea_area_name", "caba_catchment_id", "caba_catchment_name", "rivers_trust_name", "water_body_typology", "nitrates_directive", "bathing_water_directive", "drinking_water_protected_area", "shellfish_water_directive", "overall_water_body_objective", "ecological_objective", "chemical_objective", "surveillance_water_body", "habitats_and_species_directive")}
            yield (code, p.get("water_body_name"), CAT.get(p.get("water_body_type"), "river"), p.get("water_body_hmd"), "ENG" if p.get("country") in (None, "England") else ("WLS" if p.get("country") == "Wales" else None),
                   str(p.get("rbd_id")), str(p.get("mancat_id")), str(p.get("opcat_id")),
                   json.dumps(d["line"]) if d.get("line") else None, json.dumps(d["poly"]) if d.get("poly") else None, jdump(attrs))
    copy_rows(cur, "stg_wb", ["code", "name", "category", "designation", "country", "rbd", "man", "opc", "line", "poly", "attrs"], wbrows())
    cur.execute("""insert into core.waterbody (wb_code, name, category, designation, country, rbd_id, mancat_id, opcat_id, line_geom, catchment_geom, area_km2, length_km, source_id, attrs)
        select s.code, s.name, s.category, s.designation, s.country,
               r.id, m.id, o.id,
               case when s.line is not null then ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON(s.line), 4326)) end,
               case when s.poly is not null then ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(s.poly), 4326)), 3)) end,
               case when s.poly is not null then ST_Area(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(s.poly), 4326), 27700)) / 1e6 end,
               case when s.line is not null then ST_Length(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(s.line), 4326), 27700)) / 1e3 end,
               %s, s.attrs::jsonb
        from stg_wb s
        left join core.catchment r on r.kind='rbd' and r.code = s.rbd
        left join core.catchment m on m.kind='management' and m.code = s.man
        left join core.catchment o on o.kind='operational' and o.code = s.opc
        on conflict (wb_code) do nothing""", (src_c4,))
    cur.execute("select wb_code, id from core.waterbody"); WB = dict(cur.fetchall()); print("waterbodies", len(WB), round(time.time() - t0, 1), "s")
    # dissolve polygons up the hierarchy
    for kind, col in (("operational", "opcat_id"), ("management", "mancat_id"), ("rbd", "rbd_id")):
        cur.execute(f"""update core.catchment c set geom = g.geom, area_km2 = ST_Area(ST_Transform(g.geom, 27700)) / 1e6 from (
              select {col} cid, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_UnaryUnion(ST_Collect(ST_MakeValid(ST_SnapToGrid(catchment_geom, 0.00001))))), 3)) geom
              from core.waterbody where catchment_geom is not null and {col} is not null group by {col}) g where g.cid = c.id and c.kind = %s""", (kind,))
    # identifiers: also accept un-prefixed forms
    cur.execute("insert into core.waterbody_identifier (scheme, value, waterbody_id, source_id) select 'wfd_id', wb_code, id, %s from core.waterbody on conflict do nothing", (src_c4,))

    # ── classification, cycle 4 (2025) from layer columns
    cur.execute("create temp table stg_cl (wb_code text, cycle smallint, year smallint, element text, status_native text, certainty text, src bigint) on commit drop")
    rows = []
    for f in lines:
        p = f["properties"]
        if p["water_body_id"] not in WB: continue
        yr = int(p.get("classification_year") or 2025)
        for col, el in C4.items():
            v = p.get(col)
            if v in (None, "", " "): continue
            cert = p.get("eco_certainty_less_than_good") if el == "ecological" else (p.get("chem_certainty_less_than_good") if el == "chemical" else None)
            rows.append((p["water_body_id"], 4, yr, el, v, cert, src_c4))
    copy_rows(cur, "stg_cl", ["wb_code", "cycle", "year", "element", "status_native", "certainty", "src"], rows); print("c4 rows", len(rows))

    # ── historical classification from CDE CSV (cycles 1-3)
    cur.execute("select code, native_names from ref.classification_element"); EL = {}
    for code, names in cur.fetchall():
        for nm in names: EL[nm.lower()] = code
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
            rows.append((wid, int(cy), int(yr), code, st, ce if isinstance(ce, str) else None, src_cde))
    print("cde rows", len(rows), "new elements", len(new_el), round(time.time() - t0, 1), "s")
    for code, (item, lvl) in new_el.items():
        level = "specific_pollutant" if lvl in ("Component", "Sub Element") else "other"
        cur.execute("insert into ref.classification_element (code, label, level, native_names) values (%s,%s,%s,%s) on conflict do nothing", (code, item, level, [item]))
    copy_rows(cur, "stg_cl", ["wb_code", "cycle", "year", "element", "status_native", "certainty", "src"], rows)
    cur.execute("select native, canonical, rank from ref.value_map where domain='wfd_status'")
    cur.execute("create temp table stg_vm (native text, canonical text, rank smallint) on commit drop")
    copy_rows(cur, "stg_vm", ["native", "canonical", "rank"], [(k, v[0], v[1]) for k, v in VM.items()])
    cur.execute("""insert into core.waterbody_classification (waterbody_id, cycle, year, element_code, status, status_rank, status_native, certainty, source_id)
        select distinct on (w.id, s.cycle, s.year, s.element, s.src) w.id, s.cycle, s.year, s.element, coalesce(v.canonical, 'not_assessed'), v.rank, s.status_native, s.certainty, s.src
        from stg_cl s join core.waterbody w on w.wb_code = s.wb_code left join stg_vm v on v.native = lower(s.status_native)
        on conflict do nothing""")
    cur.execute("select count(*) from core.waterbody_classification"); print("classification rows", cur.fetchone()[0], round(time.time() - t0, 1), "s")

    # ── RNAG
    cur.execute("select code, native_names from ref.pressure_sector"); SEC = {}
    for code, names in cur.fetchall():
        for nm in names: SEC[nm.lower()] = code
    rn = pd.read_csv(gzip.open(os.path.join(RAW, "cde", "england_rnags.csv.gz")), dtype=str)
    rn = rn[rn["Water Body ID"].isin(WB.keys())]
    cur.execute("create temp table stg_rn (wb_code text, cycle smallint, element text, reason_type text, sector text, sector_native text, activity text, pressure text, certainty text, skey text) on commit drop")
    rows = []
    for r in rn.itertuples(index=False):
        d = r._asdict() if hasattr(r, "_asdict") else {}
    for _, r in rn.iterrows():
        el = EL.get(str(r.get("Classification Element", "")).lower())
        rows.append((r["Water Body ID"], int(r["Cycle"]) if str(r.get("Cycle")).isdigit() else None, el, r.get("Reason Type") if r.get("Reason Type") in ("RNAG", "RFD") else "RNAG",
                     SEC.get(str(r.get("Category", "")).lower(), "other"), r.get("Category"), r.get("Activity"), r.get("Swmi"), r.get("Category Certainty"), str(r.get("ID"))))
    copy_rows(cur, "stg_rn", ["wb_code", "cycle", "element", "reason_type", "sector", "sector_native", "activity", "pressure", "certainty", "skey"], rows)
    cur.execute("""insert into core.waterbody_reason (waterbody_id, cycle, element_code, reason_type, sector_code, sector_native, activity, pressure_type, certainty, source_id, source_key)
        select w.id, s.cycle, e.code, s.reason_type, s.sector, s.sector_native, s.activity, s.pressure, s.certainty, %s, s.skey
        from stg_rn s join core.waterbody w on w.wb_code = s.wb_code left join ref.classification_element e on e.code = s.element on conflict do nothing""", (src_rn,))
    cur.execute("select count(*) from core.waterbody_reason"); print("reasons", cur.fetchone()[0])

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
    cur.execute("""insert into core.waterbody_apportionment (waterbody_id, pollutant, sector, load_t_yr, share_pct, model, model_version, source_id)
        select distinct on (w.id, s.pollutant, s.sector) w.id, s.pollutant, s.sector, s.load, least(100, greatest(0, s.share)), 'SEPARATE', 'CaSTCo-2021', %s
        from stg_ap s join core.waterbody w on w.wb_code = s.wb_code on conflict do nothing""", (src_sep,))
    cur.execute("select count(*) from core.waterbody_apportionment"); print("apportionment", cur.fetchone()[0])
    finish_run(cur, run, written=len(WB)); conn.commit()
print("done", round(time.time() - t0, 1), "s")
