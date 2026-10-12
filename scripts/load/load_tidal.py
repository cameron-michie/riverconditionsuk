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
    cur.execute("""insert into core.waterbody (wb_code, name, category, country, rbd_id, catchment_geom, area_km2, source_id)
        select s.code, s.name, s.category, 'ENG', r.id, g.geom, ST_Area(ST_Transform(g.geom, 27700)) / 1e6, %s
        from stg_t s left join core.catchment r on r.kind = 'rbd' and r.code = s.rbd
        cross join lateral (select ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(s.poly), 4326)), 3)) geom) g
        on conflict (wb_code) do nothing""", (src,))
    cur.execute("insert into core.waterbody_identifier (scheme, value, waterbody_id, source_id) select 'wfd_id', wb_code, id, %s from core.waterbody where category in ('transitional', 'coastal') on conflict do nothing", (src,))
    cur.execute("select wb_code, id from core.waterbody where category in ('transitional', 'coastal')"); WB = dict(cur.fetchall()); print("tidal waterbodies", len(WB))
    cur.execute("select code, native_names from ref.classification_element"); EL = {}
    for code, names in cur.fetchall():
        for nm in names: EL[nm.lower()] = code
    cur.execute("select native, canonical, rank from ref.value_map where domain = 'wfd_status'"); VM = {n.lower(): (c, r) for n, c, r in cur.fetchall()}
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
            rows.append((WB[wid], int(cy), int(yr), code, v[0] if v else "not_assessed", v[1] if v else None, st, ce if isinstance(ce, str) else None, src_cde))
    for code, (item, lvl) in new_el.items():
        cur.execute("insert into ref.classification_element (code, label, level, native_names) values (%s,%s,%s,%s) on conflict do nothing", (code, item, "specific_pollutant" if lvl in ("Component", "Sub Element") else "other", [item]))
    cur.execute("create temp table stg_c (wid bigint, cycle smallint, year smallint, el text, status text, rank smallint, native text, cert text, src bigint) on commit drop")
    copy_rows(cur, "stg_c", ["wid", "cycle", "year", "el", "status", "rank", "native", "cert", "src"], rows)
    cur.execute("""insert into core.waterbody_classification (waterbody_id, cycle, year, element_code, status, status_rank, status_native, certainty, source_id)
        select distinct on (wid, cycle, year, el, src) wid, cycle, year, el, status, rank, native, cert, src from stg_c on conflict do nothing""")
    print("classification rows", len(rows))
    # tidal links: any link whose midpoint lies in an estuary or coastal polygon belongs to that water body
    cur.execute("""update core.river_link l set waterbody_id = t.wid from (
        select distinct on (l2.id) l2.id lid, w.id wid from core.river_link l2
        join core.waterbody w on w.category in ('transitional', 'coastal') and ST_Intersects(w.catchment_geom, ST_LineInterpolatePoint(l2.geom, 0.5))
        order by l2.id, w.area_km2) t where t.lid = l.id""")
    cur.execute("select count(*) from core.river_link l join core.waterbody w on w.id = l.waterbody_id where w.category in ('transitional', 'coastal')"); print("tidal links", cur.fetchone()[0])
    conn.commit()
