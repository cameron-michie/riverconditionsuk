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
    cur.execute("insert into ref.source (slug, name, publisher, country, kind, base_url, licence, evidence_class, cadence, status) values ('ffc_fgs','Flood Guidance Statement: five-day flood risk by county and unitary authority','Flood Forecasting Centre (EA / Met Office)','ENG','rest_api','https://api.ffc-environment-agency.fgs.metoffice.gov.uk/api/public/v1','ogl3','regulator_assessment','P1D','active') on conflict (slug) do nothing")
    ffc = source_id(cur, "ffc_fgs")
    cur.execute("select value, site_id from geo.site_key where scheme = 'ea_flood:stationReference'"); BYREF = dict(cur.fetchall())
    cur.execute("select value, site_id from geo.site_key where scheme = 'nrfa:id'"); BYNRFA = dict(cur.fetchall())

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
        cur.execute("""update geo.site s set attrs = s.attrs || jsonb_strip_nulls(jsonb_build_object('datum', x.datum, 'typical_low', x.lo, 'typical_high', x.hi, 'highest_recent', x.hr,
                          'highest_recent_at', x.hra::timestamptz, 'max_on_record', x.mx, 'max_on_record_at', x.mxa::timestamptz, 'min_on_record', x.mn))
            from (select distinct on (sid) * from stg_ss) x where x.sid = s.id""")
        print("stage scales", len(rows))
    # ── NRFA flood statistics
    rows = []
    for st in (L("nrfa/station_info.json")["data"] if os.path.exists(os.path.join(RAW, "nrfa", "station_info.json")) else []):      # static NRFA file; absent on compute, QMED is already in the database
        sid = BYNRFA.get(str(st["id"]))
        if not sid: continue
        for k in ("qmed", "gdf-q05-flow", "gdf-q10-flow", "gdf-q50-flow", "gdf-q95-flow"):
            if isinstance(st.get(k), (int, float)): rows.append((sid, k.replace("-", "_"), float(st[k]), nr))
    cur.execute("create temp table stg_at (sid bigint, k text, v float8, src bigint) on commit drop"); copy_rows(cur, "stg_at", ["sid", "k", "v", "src"], rows)
    cur.execute("update geo.site s set attrs = s.attrs || x.a from (select sid, jsonb_object_agg(k, v) a from (select distinct on (sid, k) * from stg_at) y group by sid) x where x.sid = s.id")
    print("nrfa flood stats", len(rows))

    # ── forecast areas (union of mapped ONS polygons) and the five-day outlook
    fg = sorted(glob.glob(os.path.join(RAW, "flood", "fgs_detailed_*.csv")))[-1]; stid = re.search(r"fgs_detailed_(\d+)", fg).group(1)
    csvrows = list(csv.reader(open(fg))); issued = csvrows[1][2] + "T" + csvrows[1][4][:8]; data = [r for r in csvrows[4:] if len(r) > 7 and r[0]]
    names = sorted({r[0] for r in data})
    ons = {f["properties"]["CTYUA24NM"]: f for f in L("flood/ons_ctyua_2024.geojson")["features"]}
    cur.execute("delete from live.flood where kind = 'outlook'")
    cur.execute("create temp table stg_fa (name text, g text) on commit drop"); rows, miss = [], []
    for n in names:
        parts = ONS.get(n) or [n.replace("&", "and")]
        feats = [ons[x] for x in parts if x in ons]
        if len(feats) != len(parts): miss.append((n, [x for x in parts if x not in ons]))
        if feats: rows.append((n, json.dumps({"type": "GeometryCollection", "geometries": [f["geometry"] for f in feats]})))
    copy_rows(cur, "stg_fa", ["name", "g"], rows)
    # county areas change only when the statement adds one: upsert by name so ids stay stable, and drop areas no longer listed
    cur.execute("""insert into geo.area (kind, code, name, geom, area_km2, rank, source_id)
        select 'flood_outlook_area', name, name, geom, ST_Area(ST_Transform(geom, 27700)) / 1e6, 3, %s from (
          select name, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Union(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(j.value::text), 4326)))), 3)) geom
          from stg_fa, lateral json_array_elements((g::json)->'geometries') j group by name) q
        on conflict (kind, code) do update set geom = excluded.geom, area_km2 = excluded.area_km2""", (ffc,))
    cur.execute("delete from geo.area where kind = 'flood_outlook_area' and code <> all(%s)", (names,))
    cur.execute("""update geo.area set label_pt = ST_PointOnSurface(geom), geom_lo = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, 0.012)), 3)),
                   geom_mid = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, 0.0012)), 3)) where kind = 'flood_outlook_area'""")
    cur.execute("select code, id from geo.area where kind = 'flood_outlook_area'"); AID = dict(cur.fetchall())
    out = [(stid, AID[r[0]], int(r[1]), r[2], r[3], json.dumps({"rivers": r[4], "surface": r[5], "coastal": r[6], "groundwater": r[7]}), issued + "+00", ffc) for r in data if r[0] in AID]
    cur.execute("create temp table stg_ff (st text, aid bigint, day int, d date, risk text, codes text, iss text, src bigint) on commit drop")
    copy_rows(cur, "stg_ff", ["st", "aid", "day", "d", "risk", "codes", "iss", "src"], out)
    cur.execute("""insert into live.flood (kind, statement_id, area_id, day, forecast_date, risk, attrs, issued_at)
                   select 'outlook', st, aid, day, d, risk, jsonb_build_object('codes', codes::jsonb), iss::timestamptz from stg_ff on conflict do nothing""")
    print("forecast areas", len(AID), "of", len(names), "unmatched:", miss, "rows", len(out))

    # ── active warnings with polygons
    # only warnings in force are kept, and a warning area carries a polygon only while it is active
    aw = L("flood/active_warnings.json"); n = 0
    cur.execute("update geo.area set geom = null where kind = 'warning_area' and geom is not null"); cur.execute("delete from live.flood where kind = 'warning'")
    for w in aw["warnings"]:
        code = w["floodAreaID"]; poly = aw["polygons"].get(w["floodArea"]["notation"])
        cur.execute("insert into geo.area (kind, code, name, source_id, attrs) values ('warning_area', %s, %s, %s, jsonb_build_object('kind', 'warning')) on conflict (kind, code) do nothing", (code, w.get("description"), ea))
        cur.execute("select id from geo.area where kind = 'warning_area' and code = %s", (code,)); aid = cur.fetchone()[0]
        if poly and poly.get("features"):
            geoms = [json.dumps(f["geometry"]) for f in poly["features"] if f.get("geometry")]
            if geoms: cur.execute("update geo.area set geom = (select ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Union(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)))), 3)) from unnest(%s::text[]) g) where id = %s", (geoms, aid))
        cur.execute("""insert into live.flood (kind, area_id, severity, message, issued_at, changed_at, attrs) values ('warning', %s, %s, %s, %s, %s, jsonb_build_object('fetched_at', now()))
                       on conflict (area_id) where kind = 'warning' do update set severity = excluded.severity, message = excluded.message, changed_at = excluded.changed_at""",
                    (aid, w.get("severityLevel"), w.get("message"), w.get("timeRaised") or None, w.get("timeSeverityChanged") or None)); n += 1
    print("warnings", n)
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
