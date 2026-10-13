"""Welsh waterbodies + cycle-3 classification + SAC phosphorus compliance -> geo.waterbody (classes folded to the latest per element)."""
import json, os, time
from db import *
t0 = time.time()
E = {"overallwb": "overall", "ecological": "ecological", "chem": "chemical", "fish": "fish", "inverts": "invertebrates", "mac_phyto": "macrophytes_phytobenthos",
     "nh3": "ammonia", "do": "dissolved_oxygen", "ph": "ph", "p": "phosphate", "temp": "temperature"}
CONF = {"fish": "fish_conf", "inverts": "inverts_conf", "mac_phyto": "mac_phyto_conf", "nh3": "nh3_conf", "do": "do_conf", "ph": "ph_conf", "p": "p_conf"}
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "nrw_datamap_wfs")
    feats = json.load(open(os.path.join(RAW, "wfd", "wales_c3_baseline_classification.geojson")))["features"]
    VM = wfd_status_map(cur)
    cur.execute("create temp table stg_wb (code text, name text, category text, des text, rbd text, man text, opc text, g text) on commit drop")
    rows = []
    for f in feats:
        p = f["properties"]
        if not f.get("geometry") or not p.get("waterbody_id"): continue
        rows.append((p["waterbody_id"], p.get("wb_name"), {"River": "river", "Canal": "canal", "Lake": "lake"}.get((p.get("wb_type") or "").strip(), "river"), p.get("hm_desig"),
                     (p.get("rbd") or "").strip() or None, (p.get("man_catch") or "").strip() or None, (p.get("op_catch") or "").strip() or None, json.dumps(f["geometry"])))
    copy_rows(cur, "stg_wb", ["code", "name", "category", "des", "rbd", "man", "opc", "g"], rows)
    cur.execute("""insert into geo.waterbody (wb_code, name, category, designation, country, rbd, management_catchment, operational_catchment, catchment_geom, area_km2, source_id, ids)
        select s.code, s.name, s.category, s.des, 'WLS', s.rbd, s.man, s.opc,
               ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(s.g), 4326)), 3)),
               ST_Area(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(s.g), 4326), 27700)) / 1e6, %s, jsonb_build_object('wfd_id', s.code)
        from stg_wb s on conflict (wb_code) do nothing""", (src,))
    cur.execute("select count(*) from geo.waterbody where country='WLS'"); print("welsh waterbodies", cur.fetchone()[0])
    cur.execute("select wb_code, id from geo.waterbody where country='WLS'"); WB = dict(cur.fetchall())
    cur.execute("create temp table stg_cl (wb text, el text, st text, cert text) on commit drop")
    rows = []
    for f in feats:
        p = f["properties"]
        if p.get("waterbody_id") not in WB: continue
        for col, el in E.items():
            if p.get(col): rows.append((p["waterbody_id"], el, p[col], p.get(CONF.get(col, "x"))))
    copy_rows(cur, "stg_cl", ["wb", "el", "st", "cert"], rows)
    cur.execute("create temp table stg_vm (native text, canonical text) on commit drop")
    copy_rows(cur, "stg_vm", ["native", "canonical"], [(k, v[0]) for k, v in VM.items()])
    cur.execute("""create temp table stg_cls on commit drop as
        select w.id waterbody_id, 3::smallint as cycle, 2021::smallint as year, s.el element, coalesce(v.canonical, 'not_assessed') status, s.cert certainty
        from stg_cl s join geo.waterbody w on w.wb_code = s.wb left join stg_vm v on v.native = lower(s.st)""")
    # SAC river phosphorus compliance (official target assessment) as its own element
    cur.execute("""insert into ref.term (domain, code, label, attrs) values ('wfd_element', 'sac_phosphorus', 'SAC river phosphorus target compliance',
                   '{"level": "physico_chemical", "signal_code": "chemical"}') on conflict do nothing""")
    sac = json.load(open(os.path.join(RAW, "wfd", "wales_nrw_sac_phosphorus_compliance_2017_19.geojson")))["features"]
    n = 0
    for f in sac:
        p = f["properties"]; wid = WB.get(p.get("waterbody_id"))
        if not wid: continue
        ok = (p.get("overall_ass") or "").lower().startswith("comply")
        cur.execute("insert into stg_cls values (%s, 3, 2019, 'sac_phosphorus', %s, %s)", (wid, "pass" if ok else "fail", p.get("method"))); n += 1
    print("sac rows", n, "waterbodies classified", fold_classes(cur, "stg_cls"))
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
