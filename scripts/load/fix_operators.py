"""Permit holders arrive as 'ANGLIAN WATER SERVICES LIMITED', 'DWR CYMRU CYFYNGEDIG' ... map them onto ref.organisation (water companies) by keyword."""
import json, os, re, collections
from db import *
KEY = [("anglian", "anglian_water"), ("northumbrian", "northumbrian_water"), ("severn trent", "severn_trent"), ("south west water", "south_west_water"), ("southern water", "southern_water"), ("thames water", "thames_water"),
       ("united utilities", "united_utilities"), ("wessex", "wessex_water"), ("yorkshire water", "yorkshire_water"), ("dwr cymru", "dwr_cymru"), ("welsh water", "dwr_cymru"), ("hafren dyfrdwy", "hafren_dyfrdwy"), ("scottish water", "scottish_water")]
with connect() as conn, conn.cursor() as cur:
    cur.execute("select slug, id from ref.organisation"); ORG = dict(cur.fetchall())
    cur.execute("select value, site_id from core.site_identifier where scheme = 'permit'"); BYPERMIT = dict(cur.fetchall())
    rows, names = [], collections.Counter()
    for f in json.load(open(os.path.join(RAW, "castco", "consented_sewage_discharges__0.geojson")))["features"]:
        p = f["properties"]; nm = (p.get("COMPANY_NAME") or "").lower(); names[nm] += 1
        org = next((ORG[v] for k, v in KEY if k in nm), None); sid = BYPERMIT.get(f"{p.get('PERMIT_NUMBER')}:{p.get('DISCHARGE_NGR')}")
        if org and sid: rows.append((sid, org, p.get("PERMIT_NUMBER")))
    cur.execute("create temp table stg_op (sid bigint, org bigint, permit text) on commit drop"); copy_rows(cur, "stg_op", ["sid", "org", "permit"], rows)
    cur.execute("update core.site s set operator_id = o.org from stg_op o where o.sid = s.id and s.operator_id is null")
    cur.execute("update core.permit p set holder_id = o.org from stg_op o where o.sid = p.site_id and p.holder_id is null")
    cur.execute("select core.refresh_sewage_works()")
    cur.execute("select o.name, count(*) from core.sewage_works w join ref.organisation o on o.id = w.company_id group by 1 order by 2 desc"); print(cur.fetchall())
    cur.execute("select count(*) filter (where company_id is null) from core.sewage_works"); print("works without company:", cur.fetchone()[0], "| top unmatched holder names:", [n for n, c in names.most_common(12) if not any(k in n for k, _ in KEY)][:6])
    conn.commit()
