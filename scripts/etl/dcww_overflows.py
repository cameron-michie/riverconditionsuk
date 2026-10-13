"""Welsh Water live storm overflow layer -> geo.site (once per new asset) and live.site_now (every run).
Existing Welsh Water overflow sites within 30 m are reused; new assets are snapped to the river network like every other site.
Times in the feed carry no zone: read as UK local time."""
import datetime as dt, json, os, sys
import common, lib
from zoneinfo import ZoneInfo
from db import connect, copy_rows, source_id, start_run, finish_run

U = "https://services3.arcgis.com/KLNF7YxtENPLYVey/arcgis/rest/services/Spill_Prod__External/FeatureServer/0/query"
UK = ZoneInfo("Europe/London"); UTC = dt.timezone.utc
MAP = {"Overflow Operating": "discharging", "Overflow Not Operating": "not_discharging", "Overflow Not Operating (Has in the last 24 hours)": "not_discharging", "Under Investigation": "offline"}

def fetch():
    out, off = [], 0
    while True:                                   # lib.arcgis_all hangs on this service; plain offset paging takes ~3 s
        fs = lib.get(U, params={"where": "1=1", "outFields": "*", "orderByFields": "objectid", "resultOffset": off, "resultRecordCount": 500, "f": "geojson"}, timeout=60).json().get("features", [])
        out += fs; off += len(fs)
        if len(fs) < 500: return out

def local(s):
    try: return dt.datetime.fromisoformat(s).replace(tzinfo=UK).astimezone(UTC) if s else None
    except ValueError: return None

with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "dcww_overflow_live"); run = start_run(cur, "dcww_overflow_live", "dcww_overflows")
    feats = [f for f in fetch() if f.get("geometry") and f["properties"].get("DCWW_ID")]
    cur.execute("select id from ref.organisation where slug = 'dwr_cymru'"); ORG = cur.fetchone()[0]
    cur.execute("select value, site_id from geo.site_key where scheme = 'dcww:id'"); SITE = dict(cur.fetchall()); new = []
    for f in feats:
        p = f["properties"]; i = p["DCWW_ID"]
        if i in SITE: continue
        lon, lat = f["geometry"]["coordinates"][:2]
        cur.execute("""select s.id from geo.site s where s.kind = 'storm_overflow' and s.operator_id = %s and s.id <> all(%s)
                       and ST_DWithin(s.geom_bng, ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700), 30) order by s.geom_bng <-> ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700) limit 1""", (ORG, list(SITE.values()) or [0], lon, lat, lon, lat))
        m = cur.fetchone()
        if m: sid, kind = m[0], "crosswalk"
        else:
            cur.execute("""insert into geo.site (kind, name, geom, geom_bng, country, operator_id, status, primary_source_id, river_name_raw, attrs)
                           values ('storm_overflow', %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326), ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700),
                                   (select case b.name when 'England' then 'ENG' when 'Wales' then 'WLS' when 'Scotland' then 'SCT' end from geo.area b where b.kind = 'country' and ST_Intersects(b.geom_lo, ST_SetSRID(ST_MakePoint(%s, %s), 4326)) limit 1),
                                   %s, 'active', %s, %s, %s) returning id""",
                        (p["asset_name"], lon, lat, lon, lat, lon, lat, ORG, S, p.get("Receiving_Water"),
                         json.dumps({"dcww_id": i, "asset_type": (p.get("Overflow") or "storm").lower(), "receiving": p.get("Receiving_Water"), "legacy_ids": [i],
                                     "linked_bathing_water": p.get("Linked_Bathing_Water") or None})))
            sid, kind = cur.fetchone()[0], "native"; new.append(sid)
        cur.execute("insert into geo.site_key (scheme, value, site_id) values ('dcww:id', %s, %s) on conflict do nothing", (i, sid)); SITE[i] = sid
    if new:   # snap new sites to the river network and its waterbody (same rule as scripts/load/snap_sites.sql, 500 m tolerance)
        cur.execute("""with k as (select s.id sid, n.id lid, n.river_id, n.waterbody_id, n.length_m, n.dist_to_mouth_m, ST_Distance(s.geom_bng, n.geom_bng) d, ST_LineLocatePoint(n.geom_bng, s.geom_bng) frac
                                 from geo.site s cross join lateral (select * from geo.river_link order by geom_bng <-> s.geom_bng limit 1) n where s.id = any(%s))
                       update geo.site s set snap_distance_m = k.d, river_link_id = case when k.d <= 500 then k.lid end, river_id = case when k.d <= 500 then k.river_id end,
                              waterbody_id = coalesce(case when k.d <= 500 then k.waterbody_id end, (select w.id from geo.waterbody w where w.catchment_geom is not null and ST_Intersects(w.catchment_geom, s.geom) order by w.area_km2 limit 1)),
                              dist_to_mouth_m = case when k.d <= 500 then greatest(0, k.dist_to_mouth_m - k.frac * coalesce(k.length_m, 0)) end from k where k.sid = s.id""", (new,))
    rows = []
    for f in feats:
        p = f["properties"]; sid = SITE[p["DCWW_ID"]]; rep = dt.datetime.fromtimestamp(p["EditDate"] / 1000, UTC) if p.get("EditDate") else None
        rows.append((sid, MAP.get(p["status"], "unknown"), p["status"], None, local(p.get("start_date_time_discharge")), local(p.get("stop_date_time_discharge")), rep, S))
    cur.execute("create temp table stg_o (sid bigint, st text, raw text, since timestamptz, ls timestamptz, le timestamptz, rep timestamptz, src bigint) on commit drop")
    copy_rows(cur, "stg_o", ["sid", "st", "raw", "since", "ls", "le", "rep", "src"], rows)
    cur.execute("""insert into live.site_now (site_id, kind, state, since, at, detail)
                   select sid, 'overflow', st, since, rep, jsonb_strip_nulls(jsonb_build_object('raw_status', raw, 'last_event_start', ls, 'last_event_end', le, 'source_id', src)) from stg_o
                   on conflict (site_id) do update set state = excluded.state, at = excluded.at, detail = excluded.detail, updated_at = now()""")
    cur.execute("select count(*) filter (where st = 'discharging') from stg_o"); dis = cur.fetchone()[0]
    finish_run(cur, run, read=len(feats), written=len(rows)); conn.commit()
    print(f"welsh water: {len(feats)} overflows, {len(new)} new sites, {dis} discharging now")
