"""Natural Resources Wales open telemetry: river level (241) and rainfall (148) at ~390 Welsh measures, latest value each, every 15 minutes.
Stations are matched to an existing site of the same kind within 40 m, else created and snapped to the river network. Time is UTC in the feed.
There is no history endpoint, so the record starts when this job starts."""
import datetime as dt, json, os, sys
import common, lib
from common import upsert_obs
from db import connect, source_id, start_run, finish_run

B = "https://api.naturalresources.wales/telemetry/api/"
PARAM = {"Water Level": ("water_level", "instant", "m"), "Rainfall": ("rainfall", "sum", "mm")}
with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "nrw_river_levels"); run = start_run(cur, "nrw_river_levels", "nrw_telemetry")
    stations = {s["monitoring_station_reference"]: s for s in lib.get(B + "stations").json()}
    measures = [m for m in lib.get(B + "measures").json() if m["measure_type_en"] in PARAM and m["monitoring_station_reference"] in stations]
    cur.execute("select value, site_id from core.site_identifier where scheme = 'nrw:station'"); SITE = dict(cur.fetchall())
    cur.execute("select code, id from ref.parameter"); PID = dict(cur.fetchall())
    kinds = {}
    for m in measures: kinds.setdefault(m["monitoring_station_reference"], set()).add(m["measure_type_en"])
    new = []
    for ref, ks in kinds.items():
        if ref in SITE: continue
        s = stations[ref]
        try: lat, lon = float(s["latitude"]), float(s["longitude"])
        except (TypeError, ValueError): continue
        kind = "river_gauge" if "Water Level" in ks else "rain_gauge"
        cur.execute("""select id from core.site where kind = %s and merged_into is null and id <> all(%s) and ST_DWithin(geom_bng, ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700), 40)
                       order by geom_bng <-> ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700) limit 1""", (kind, list(SITE.values()) or [0], lon, lat, lon, lat))
        m = cur.fetchone()
        if m: sid, how = m[0], "crosswalk"
        else:
            cur.execute("""insert into core.site (kind, name, geom, geom_bng, country, status, primary_source_id, river_name_raw, attrs)
                           values (%s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326), ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700), 'WLS', 'active', %s, %s, %s) returning id""",
                        (kind, s["monitoring_station_name_en"], lon, lat, lon, lat, S, s.get("river_name_en"), json.dumps({"nrw_ref": ref, "area": s.get("hydrometric_area_name")})))
            sid, how = cur.fetchone()[0], "native"; new.append(sid)
        cur.execute("insert into core.site_identifier (scheme, value, site_id, source_id, match_method) values ('nrw:station', %s, %s, %s, %s) on conflict do nothing", (ref, sid, S, how)); SITE[ref] = sid
    if new:
        cur.execute("""with k as (select s.id sid, n.id lid, n.river_id, n.waterbody_id, n.length_m, n.dist_to_mouth_m, ST_Distance(s.geom_bng, n.geom_bng) d, ST_LineLocatePoint(n.geom_bng, s.geom_bng) frac
                                 from core.site s cross join lateral (select * from core.river_link order by geom_bng <-> s.geom_bng limit 1) n where s.id = any(%s))
                       update core.site s set snap_distance_m = k.d, river_link_id = case when k.d <= 300 then k.lid end, river_id = case when k.d <= 300 then k.river_id end,
                              waterbody_id = coalesce(case when k.d <= 300 then k.waterbody_id end, (select w.id from core.waterbody w where w.catchment_geom is not null and ST_Intersects(w.catchment_geom, s.geom) order by w.area_km2 limit 1)),
                              dist_to_mouth_m = case when k.d <= 300 then greatest(0, k.dist_to_mouth_m - k.frac * coalesce(k.length_m, 0)) end from k where k.sid = s.id and s.kind <> 'rain_gauge'""", (new,))
    cur.execute("select source_series_key, id from core.series where source_id = %s", (S,)); SER = dict(cur.fetchall())
    rows, bad = [], 0
    for m in measures:
        code, agg, unit = PARAM[m["measure_type_en"]]; key = "nrw:" + m["measure_id"]; site = SITE.get(m["monitoring_station_reference"])
        try: v = float(m["latest_value"]); t = dt.datetime.strptime(m["latest_time"], "%Y-%m-%d %H:%M:%S.%fZ").replace(tzinfo=dt.timezone.utc)
        except (TypeError, ValueError): bad += 1; continue
        if site is None: bad += 1; continue
        if key not in SER:
            datum = m["units"] if m["units"] in ("mASD", "mAOD") else None
            cur.execute("""insert into core.series (site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, qualifier, datum, evidence_class)
                           values (%s, %s, %s, %s, %s, 900, %s, %s, %s, %s, 'official_monitoring') on conflict do nothing returning id""",
                        (site, PID[code], S, key, agg, unit, m["units"], "stage" if code == "water_level" else "15min_total", datum))
            x = cur.fetchone()
            if x is None: bad += 1; continue
            SER[key] = x[0]
        rows.append((SER[key], t, v, "unchecked", None))
    a, b = upsert_obs(cur, rows, update=False)
    cur.execute("select ops.flag_implausible(now() - interval '3 hours')")
    finish_run(cur, run, read=len(measures), written=b, rejected=bad); conn.commit()
    print(f"nrw: {len(measures)} measures, {len(new)} new sites, {a} readings, {b} new, {bad} skipped")
