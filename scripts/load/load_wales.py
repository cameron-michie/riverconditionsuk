"""Welsh waterbodies + cycle-3 classification + SAC phosphorus compliance."""
import json, os, time
from db import *
t0 = time.time()
E = {"overallwb": "overall", "ecological": "ecological", "chem": "chemical", "fish": "fish", "inverts": "invertebrates", "mac_phyto": "macrophytes_phytobenthos",
     "nh3": "ammonia", "do": "dissolved_oxygen", "ph": "ph", "p": "phosphate", "temp": "temperature"}
CONF = {"fish": "fish_conf", "inverts": "inverts_conf", "mac_phyto": "mac_phyto_conf", "nh3": "nh3_conf", "do": "do_conf", "ph": "ph_conf", "p": "p_conf"}
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "nrw_datamap_wfs")
    feats = json.load(open(os.path.join(RAW, "wfd", "wales_c3_baseline_classification.geojson")))["features"]
    cur.execute("select native, canonical, rank from ref.value_map where domain='wfd_status'"); VM = {n.lower(): (c, r) for n, c, r in cur.fetchall()}
    # catchment hierarchy by name (Welsh layer carries names, not ids)
    for kind, col, par in (("rbd", "rbd", None), ("management", "man_catch", "rbd"), ("operational", "op_catch", "man_catch")):
        for f in feats:
            p = f["properties"]
            if p.get(col):
                cur.execute("insert into core.catchment (kind, code, name, country, source_id) values (%s,%s,%s,'WLS',%s) on conflict (kind, code) do nothing", (kind, "w:" + p[col].strip(), p[col].strip(), src))
    cur.execute("""insert into core.catchment (kind, code, name, country, source_id)
        select 'rbd', 'w:' || x, x, 'WLS', %s from (select distinct properties->>'rbd' x from jsonb_array_elements(%s::jsonb) properties) q where false""", (src, "[]"))
    cur.execute("create temp table stg_wb (code text, name text, category text, des text, rbd text, man text, opc text, g text, attrs text) on commit drop")
    rows = []
    for f in feats:
        p = f["properties"]
        if not f.get("geometry") or not p.get("waterbody_id"): continue
        rows.append((p["waterbody_id"], p.get("wb_name"), {"River": "river", "Canal": "canal", "Lake": "lake"}.get((p.get("wb_type") or "").strip(), "river"), p.get("hm_desig"),
                     (p.get("rbd") or "").strip(), (p.get("man_catch") or "").strip(), (p.get("op_catch") or "").strip(), json.dumps(f["geometry"]),
                     jdump({"driving_element": p.get("driving_element"), "nrw_area": p.get("nrw_area"), "mitigation": p.get("mit_assmnt")})))
    copy_rows(cur, "stg_wb", ["code", "name", "category", "des", "rbd", "man", "opc", "g", "attrs"], rows)
    cur.execute("""insert into core.waterbody (wb_code, name, category, designation, country, rbd_id, mancat_id, opcat_id, catchment_geom, area_km2, source_id, attrs)
        select s.code, s.name, s.category, s.des, 'WLS', r.id, m.id, o.id,
               ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(s.g), 4326)), 3)),
               ST_Area(ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(s.g), 4326), 27700)) / 1e6, %s, s.attrs::jsonb
        from stg_wb s left join core.catchment r on r.kind='rbd' and r.code = 'w:' || s.rbd and r.country='WLS'
                      left join core.catchment m on m.kind='management' and m.code = 'w:' || s.man
                      left join core.catchment o on o.kind='operational' and o.code = 'w:' || s.opc on conflict (wb_code) do nothing""", (src,))
    cur.execute("select count(*) from core.waterbody where country='WLS'"); print("welsh waterbodies", cur.fetchone()[0])
    cur.execute("select wb_code, id from core.waterbody where country='WLS'"); WB = dict(cur.fetchall())
    cur.execute("create temp table stg_cl (wb text, el text, st text, cert text) on commit drop")
    rows = []
    for f in feats:
        p = f["properties"]
        if p.get("waterbody_id") not in WB: continue
        for col, el in E.items():
            if p.get(col): rows.append((p["waterbody_id"], el, p[col], p.get(CONF.get(col, "x"))))
    copy_rows(cur, "stg_cl", ["wb", "el", "st", "cert"], rows)
    cur.execute("create temp table stg_vm (native text, canonical text, rank smallint) on commit drop")
    copy_rows(cur, "stg_vm", ["native", "canonical", "rank"], [(k, v[0], v[1]) for k, v in VM.items()])
    cur.execute("""insert into core.waterbody_classification (waterbody_id, cycle, year, element_code, status, status_rank, status_native, certainty, source_id)
        select distinct on (w.id, s.el) w.id, 3, 2021, s.el, coalesce(v.canonical, 'not_assessed'), v.rank, s.st, s.cert, %s
        from stg_cl s join core.waterbody w on w.wb_code = s.wb left join stg_vm v on v.native = lower(s.st) on conflict do nothing""", (src,))
    # SAC river phosphorus compliance (official target assessment) as its own element
    cur.execute("insert into ref.classification_element (code, label, level, signal_code, native_names) values ('sac_phosphorus','SAC river phosphorus target compliance','physico_chemical','chemical','{}') on conflict do nothing")
    sac = json.load(open(os.path.join(RAW, "wfd", "wales_nrw_sac_phosphorus_compliance_2017_19.geojson")))["features"]
    n = 0
    for f in sac:
        p = f["properties"]; wid = p.get("waterbody_id")
        cur.execute("select id from core.waterbody where wb_code=%s", (wid,)); r = cur.fetchone()
        if not r: continue
        ok = (p.get("overall_ass") or "").lower().startswith("comply")
        cur.execute("""insert into core.waterbody_classification (waterbody_id, cycle, year, element_code, status, status_rank, status_native, certainty, source_id)
                       values (%s, 3, 2019, 'sac_phosphorus', %s, null, %s, %s, %s) on conflict do nothing""",
                    (r[0], "pass" if ok else "fail", f"{p.get('overall_ass')}: mean {p.get('ann_mean_p_ug_l')} ug/l vs standard {p.get('p_standard_ugl')} ug/l ({p.get('sacname')})", p.get("method"), src)); n += 1
    print("sac rows", n)
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
