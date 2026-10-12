"""Flood data: EA stage scales, NRFA flood statistics (QMED), FFC five-day outlook per county/UA, active warning polygons."""
import csv, glob, json, os, re, time
from db import *
t0 = time.time()
def L(p): return json.load(open(os.path.join(RAW, p)))
# FGS area name -> ONS Dec-2024 county/unitary names (unions for old-style counties)
ONS = {
 "Bath and NE Somerset": ["Bath and North East Somerset"], "Bedfordshire": ["Bedford", "Central Bedfordshire", "Luton"], "Bournemouth": ["Bournemouth, Christchurch and Poole"], "Poole": ["Bournemouth, Christchurch and Poole"],
 "Bristol": ["Bristol, City of"], "Cheshire": ["Cheshire East", "Cheshire West and Chester"], "Cornwall & Isles of Scilly": ["Cornwall", "Isles of Scilly"], "Cumbria": ["Cumberland", "Westmorland and Furness"],
 "Durham": ["County Durham"], "E Riding of Yorkshire": ["East Riding of Yorkshire"], "E Sussex": ["East Sussex"], "Herefordshire": ["Herefordshire, County of"], "Kingston upon Hull": ["Kingston upon Hull, City of"],
 "N Lincolnshire": ["North Lincolnshire"], "N Somerset": ["North Somerset"], "N Yorkshire": ["North Yorkshire"], "NE Lincolnshire": ["North East Lincolnshire"], "Northamptonshire": ["North Northamptonshire", "West Northamptonshire"],
 "Rhondda Cynon Taff": ["Rhondda Cynon Taf"], "S Gloucestershire": ["South Gloucestershire"], "W Berkshire": ["West Berkshire"], "W Sussex": ["West Sussex"],
 "Gtr Manchester": ["Bolton", "Bury", "Manchester", "Oldham", "Rochdale", "Salford", "Stockport", "Tameside", "Trafford", "Wigan"], "Merseyside": ["Knowsley", "Liverpool", "Sefton", "St. Helens", "Wirral"],
 "S Yorkshire": ["Barnsley", "Doncaster", "Rotherham", "Sheffield"], "Tyne and Wear": ["Gateshead", "Newcastle upon Tyne", "North Tyneside", "South Tyneside", "Sunderland"],
 "W Midlands": ["Birmingham", "Coventry", "Dudley", "Sandwell", "Solihull", "Walsall", "Wolverhampton"], "W Yorkshire": ["Bradford", "Calderdale", "Kirklees", "Leeds", "Wakefield"],
 "Gtr London": ["City of London", "Barking and Dagenham", "Barnet", "Bexley", "Brent", "Bromley", "Camden", "Croydon", "Ealing", "Enfield", "Greenwich", "Hackney", "Hammersmith and Fulham", "Haringey", "Harrow", "Havering", "Hillingdon", "Hounslow",
                "Islington", "Kensington and Chelsea", "Kingston upon Thames", "Lambeth", "Lewisham", "Merton", "Newham", "Redbridge", "Richmond upon Thames", "Southwark", "Sutton", "Tower Hamlets", "Waltham Forest", "Wandsworth", "Westminster"],
}
with connect() as conn, conn.cursor() as cur:
    ea = source_id(cur, "ea_flood_monitoring"); nr = source_id(cur, "nrfa")
    cur.execute("insert into ingest.source (slug, name, publisher, country, kind, base_url, licence_id, evidence_class, cadence, expected_lag, status, status_note) values ('ffc_fgs','Flood Guidance Statement: five-day flood risk by county and unitary authority','Flood Forecasting Centre (EA / Met Office)','ENG','rest_api','https://api.ffc-environment-agency.fgs.metoffice.gov.uk/api/public/v1',(select id from ingest.licence where slug='ogl3'),'regulator_assessment','P1D','PT1H','active','v1 public endpoint still answers but v1 and v2 were announced as decommissioned after 30 Jun 2026; v3 needs a free API key. England and Wales only; Scotland has no equivalent loaded.') on conflict (slug) do nothing")
    ffc = source_id(cur, "ffc_fgs")
    cur.execute("select value, site_id from core.site_identifier where scheme = 'ea_flood:stationReference'"); BYREF = dict(cur.fetchall())
    cur.execute("select value, site_id from core.site_identifier where scheme = 'nrfa:id'"); BYNRFA = dict(cur.fetchall())

    # ── stage scales
    p = os.path.join(RAW, "ea_flood", "stagescale.json")
    if os.path.exists(p):
        ss = json.load(open(p)); rows = []
        for ref, d in ss.items():
            sid = BYREF.get(ref)
            if not sid or not isinstance(d, dict): continue
            g = lambda k, f="value": (lambda v: v if isinstance(v, (int, float, str)) else None)((d.get(k) if isinstance(d.get(k), dict) else {}).get(f))
            num = lambda v: v if isinstance(v, (int, float)) else None
            rows.append((sid, num(d.get("datum")), num(d.get("typicalRangeLow")), num(d.get("typicalRangeHigh")), g("highestRecent"), g("highestRecent", "dateTime"), g("maxOnRecord"), g("maxOnRecord", "dateTime"), g("minOnRecord")))
        cur.execute("create temp table stg_ss (sid bigint, datum float8, lo float8, hi float8, hr float8, hra text, mx float8, mxa text, mn float8) on commit drop")
        copy_rows(cur, "stg_ss", ["sid", "datum", "lo", "hi", "hr", "hra", "mx", "mxa", "mn"], rows)
        cur.execute("""insert into core.site_stage_scale (site_id, datum, typical_low, typical_high, highest_recent, highest_recent_at, max_on_record, max_on_record_at, min_on_record, source_id)
            select distinct on (sid) sid, datum, lo, hi, hr, hra::timestamptz, mx, mxa::timestamptz, mn, %s from stg_ss
            on conflict (site_id) do update set datum = excluded.datum, typical_low = excluded.typical_low, typical_high = excluded.typical_high, highest_recent = excluded.highest_recent, max_on_record = excluded.max_on_record, min_on_record = excluded.min_on_record""", (ea,))
        print("stage scales", len(rows))
    # ── NRFA flood statistics
    rows = []
    for st in L("nrfa/station_info.json")["data"]:
        sid = BYNRFA.get(str(st["id"]))
        if not sid: continue
        for k in ("qmed", "gdf-q05-flow", "gdf-q10-flow", "gdf-q50-flow", "gdf-q95-flow"):
            if isinstance(st.get(k), (int, float)): rows.append((sid, k.replace("-", "_"), float(st[k]), nr))
    cur.execute("create temp table stg_at (sid bigint, k text, v float8, src bigint) on commit drop"); copy_rows(cur, "stg_at", ["sid", "k", "v", "src"], rows)
    cur.execute("insert into core.site_attribute (site_id, key, value_num, source_id) select distinct on (sid, k) sid, k, v, src from stg_at on conflict (site_id, key, source_id) do update set value_num = excluded.value_num")
    print("nrfa flood stats", len(rows))

    # ── forecast areas (union of mapped ONS polygons) and the five-day outlook
    fg = sorted(glob.glob(os.path.join(RAW, "flood", "fgs_detailed_*.csv")))[-1]; stid = re.search(r"fgs_detailed_(\d+)", fg).group(1)
    csvrows = list(csv.reader(open(fg))); issued = csvrows[1][2] + "T" + csvrows[1][4][:8]; data = [r for r in csvrows[4:] if len(r) > 7 and r[0]]
    names = sorted({r[0] for r in data})
    ons = {f["properties"]["CTYUA24NM"]: f for f in L("flood/ons_ctyua_2024.geojson")["features"]}
    cur.execute("delete from core.flood_forecast"); cur.execute("delete from core.boundary where kind = 'flood_area'")
    cur.execute("create temp table stg_fa (name text, g text) on commit drop"); rows, miss = [], []
    for n in names:
        parts = ONS.get(n) or [n.replace("&", "and")]
        feats = [ons[x] for x in parts if x in ons]
        if len(feats) != len(parts): miss.append((n, [x for x in parts if x not in ons]))
        if feats: rows.append((n, json.dumps({"type": "GeometryCollection", "geometries": [f["geometry"] for f in feats]})))
    copy_rows(cur, "stg_fa", ["name", "g"], rows)
    cur.execute("""insert into core.boundary (kind, code, name, geom, area_km2, rank, source_id)
        select 'flood_area', name, name, geom, ST_Area(ST_Transform(geom, 27700)) / 1e6, 3, %s from (
          select name, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Union(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(j.value::text), 4326)))), 3)) geom
          from stg_fa, lateral json_array_elements((g::json)->'geometries') j group by name) q""", (ffc,))
    cur.execute("""update core.boundary set label_pt = ST_PointOnSurface(geom), geom_lo = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, 0.012)), 3)),
                   geom_mid = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, 0.0012)), 3)) where kind = 'flood_area'""")
    cur.execute("select code, id from core.boundary where kind = 'flood_area'"); AID = dict(cur.fetchall())
    out = [(stid, AID[r[0]], int(r[1]), r[2], r[3], json.dumps({"rivers": r[4], "surface": r[5], "coastal": r[6], "groundwater": r[7]}), issued + "+00", ffc) for r in data if r[0] in AID]
    cur.execute("create temp table stg_ff (st text, aid bigint, day int, d date, risk text, codes text, iss text, src bigint) on commit drop")
    copy_rows(cur, "stg_ff", ["st", "aid", "day", "d", "risk", "codes", "iss", "src"], out)
    cur.execute("insert into core.flood_forecast (statement_id, area_id, day, forecast_date, risk, codes, issued_at, source_id) select st, aid, day, d, risk, codes::jsonb, iss::timestamptz, src from stg_ff on conflict do nothing")
    print("forecast areas", len(AID), "of", len(names), "unmatched:", miss, "rows", len(out))

    # ── active warnings with polygons
    aw = L("flood/active_warnings.json"); cur.execute("update core.flood_area set geom_active = null where geom_active is not null"); n = 0
    for w in aw["warnings"]:
        code = w["floodAreaID"]; poly = aw["polygons"].get(w["floodArea"]["notation"])
        cur.execute("insert into core.flood_area (code, name, kind, source_id) values (%s,%s,%s,%s) on conflict (code) do nothing", (code, w.get("description"), "warning", ea))
        cur.execute("select id from core.flood_area where code = %s", (code,)); aid = cur.fetchone()[0]
        if poly and poly.get("features"):
            geoms = [json.dumps(f["geometry"]) for f in poly["features"] if f.get("geometry")]
            if geoms: cur.execute("update core.flood_area set geom_active = (select ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Union(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)))), 3)) from unnest(%s::text[]) g) where id = %s", (geoms, aid))
        cur.execute("insert into core.flood_warning (area_id, severity_level, message, raised_at, changed_at, fetched_at, source_id) values (%s,%s,%s,%s,%s,now(),%s) on conflict do nothing",
                    (aid, w.get("severityLevel"), w.get("message"), w.get("timeRaised") or None, w.get("timeSeverityChanged") or None, ea)); n += 1
    print("warnings", n)
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
