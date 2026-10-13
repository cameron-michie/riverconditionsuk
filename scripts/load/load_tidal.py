"""Transitional (estuary) and coastal water bodies: polygons from the EA WFS, classification from the CDE export, tidal river links assigned to them."""
import json, os, re
import pandas as pd
from db import *
slug = lambda s: re.sub(r"[^a-z0-9]+", "_", str(s).lower()).strip("_")
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "castco_wfd_c4"); src_cde = source_id(cur, "ea_cde_classification")
    feats = json.load(open(os.path.join(RAW, "wfd", "trac_cycle2.json")))["features"]
    cur.execute("create temp table stg_t (code text, name text, category text, rbd text, poly text) on commit drop")
    copy_rows(cur, "stg_t", ["code", "name", "category", "rbd", "poly"], ((f["properties"]["wb_id"], f["properties"]["wb_name"].title() if f["properties"]["wb_name"].isupper() else f["properties"]["wb_name"], f["properties"]["wb_cat"].lower(), str(f["properties"]["rbd_id"]), json.dumps(f["geometry"])) for f in feats))
    cur.execute("""insert into geo.waterbody (wb_code, name, category, country, catchment_geom, area_km2, source_id, ids)
        select s.code, s.name, s.category, 'ENG', g.geom, ST_Area(ST_Transform(g.geom, 27700)) / 1e6, %s, jsonb_build_object('wfd_id', s.code, 'rbd_id', s.rbd)
        from stg_t s
        cross join lateral (select ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(s.poly), 4326)), 3)) geom) g
        on conflict (wb_code) do nothing""", (src,))
    cur.execute("select wb_code, id from geo.waterbody where category in ('transitional', 'coastal')"); WB = dict(cur.fetchall()); print("tidal waterbodies", len(WB))
    EL = term_native(cur, "wfd_element"); VM = wfd_status_map(cur)
    rows, new_el = [], {}
    for ch in pd.read_csv(os.path.join(RAW, "wfd_england_classifications.csv"), dtype=str, chunksize=200000,
                          usecols=["Water Body ID", "Year", "Status", "Cycle", "Classification Level", "Classification Item", "Certainty"]):
        ch = ch[ch["Water Body ID"].isin(WB.keys())]
        for wid, yr, st, cy, lvl, item, ce in ch.itertuples(index=False):
            if not isinstance(item, str) or not isinstance(st, str): continue
            code = EL.get(item.lower())
            if code is None:
                code = "x_" + slug(item)[:60]; EL[item.lower()] = code; new_el[code] = (item, lvl)
            v = VM.get(st.lower())
            rows.append((WB[wid], int(cy), int(yr), code, v[0] if v else "not_assessed", ce if isinstance(ce, str) else None))
    for code, (item, lvl) in new_el.items():
        cur.execute("insert into ref.term (domain, code, label, native, attrs) values ('wfd_element', %s, %s, %s, jsonb_build_object('level', %s::text)) on conflict do nothing",
                    (code, item, [item], "specific_pollutant" if lvl in ("Component", "Sub Element") else "other"))
    cur.execute("create temp table stg_c (waterbody_id bigint, cycle smallint, year smallint, element text, status text, certainty text) on commit drop")
    copy_rows(cur, "stg_c", ["waterbody_id", "cycle", "year", "element", "status", "certainty"], rows)
    print("classification rows", len(rows), "waterbodies classified", fold_classes(cur, "stg_c"))
    # tidal links: any link whose midpoint lies in an estuary or coastal polygon belongs to that water body
    cur.execute("""update geo.river_link l set waterbody_id = t.wid from (
        select distinct on (l2.id) l2.id lid, w.id wid from geo.river_link l2
        join geo.waterbody w on w.category in ('transitional', 'coastal') and ST_Intersects(w.catchment_geom, ST_LineInterpolatePoint(l2.geom, 0.5))
        order by l2.id, w.area_km2) t where t.lid = l.id""")
    cur.execute("select count(*) from geo.river_link l join geo.waterbody w on w.id = l.waterbody_id where w.category in ('transitional', 'coastal')"); print("tidal links", cur.fetchone()[0])
    conn.commit()
