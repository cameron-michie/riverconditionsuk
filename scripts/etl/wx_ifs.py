"""ECMWF IFS open data (0.25 deg): 5-day rain + mean sea level pressure from the newest complete run.
  rain  -> live.weather 'ifs_rain' (PNG per 3 h step) and live.rain source 'ifs' (one row of steps per waterbody)
  MSLP  -> live.weather 'ifs_mslp' (one row per step, isobars every 2 hPa as line coordinates)
Each run replaces the previous one."""
import datetime as dt, json, os, sys, tempfile
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load"), os.path.dirname(os.path.abspath(__file__))]
import eccodes, numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates, zoom
from shapely.geometry import MultiLineString
from skimage.measure import find_contours
import lib, wxlib
from db import connect, copy_rows, start_run, finish_run
import store
WS = store.weather()

BASE = "https://data.ecmwf.int/forecasts"
STEP, LAST = 3, 120
REGION = (-14.0, 47.0, 6.0, 63.0)      # minlon, minlat, maxlon, maxlat kept for contouring
now = dt.datetime.now(dt.timezone.utc)

def url(run, step, ext): return f"{BASE}/{run:%Y%m%d}/{run:%H}z/ifs/0p25/oper/{run:%Y%m%d%H}0000-{step}h-oper-fc.{ext}"
def newest_complete_run():
    t = now.replace(minute=0, second=0, microsecond=0); t = t.replace(hour=t.hour // 12 * 12)
    for _ in range(6):
        try:
            r = lib.get(url(t, LAST, "index"))
            if r.status_code == 200 and len(r.text) > 1000: return t
        except Exception: pass
        t -= dt.timedelta(hours=12)
    raise SystemExit("no complete IFS run found")

def field(run, step, param):
    idx = [json.loads(l) for l in lib.get(url(run, step, "index")).text.splitlines()]
    e = next(x for x in idx if x["param"] == param and x.get("levtype") == "sfc")
    raw = lib.get(url(run, step, "grib2"), headers={"Range": f"bytes={e['_offset']}-{e['_offset'] + e['_length'] - 1}"}).content
    with tempfile.NamedTemporaryFile(suffix=".grib2") as f:
        f.write(raw); f.flush()
        with open(f.name, "rb") as fh:
            g = eccodes.codes_grib_new_from_file(fh)
            ni, nj = eccodes.codes_get(g, "Ni"), eccodes.codes_get(g, "Nj")
            v = eccodes.codes_get_values(g).reshape(nj, ni)
            lat0, lon0 = eccodes.codes_get(g, "latitudeOfFirstGridPointInDegrees"), eccodes.codes_get(g, "longitudeOfFirstGridPointInDegrees")
            dlat = eccodes.codes_get(g, "jDirectionIncrementInDegrees"); dlon = eccodes.codes_get(g, "iDirectionIncrementInDegrees"); eccodes.codes_release(g)
    return v, lat0, lon0, dlat, dlon                      # row 0 = lat0 (north), longitudes start at lon0 (0..360 or -180..180)

def crop(v, lat0, lon0, dlat, dlon, box):
    """sub-grid inside box. Returns (array rows north->south, lons, lats)."""
    lats = lat0 - dlat * np.arange(v.shape[0]); lons = lon0 + dlon * np.arange(v.shape[1]); lons = np.where(lons > 180, lons - 360, lons)
    order = np.argsort(lons); v, lons = v[:, order], lons[order]
    ri = np.where((lats >= box[1]) & (lats <= box[3]))[0]; ci = np.where((lons >= box[0]) & (lons <= box[2]))[0]
    return v[np.ix_(ri, ci)], lons[ci], lats[ri]

def sample(arr, lons, lats, lon, lat):
    """bilinear sample of arr (rows north->south) at points."""
    x = (np.asarray(lon) - lons[0]) / (lons[1] - lons[0]); y = (lats[0] - np.asarray(lat)) / (lats[0] - lats[1])
    return map_coordinates(arr, [y, x], order=1, mode="nearest")

os.makedirs(os.path.join(wxlib.WX_DIR, "ifs"), exist_ok=True)
run = newest_complete_run()
with connect() as conn, conn.cursor() as cur:
    cur.execute("select 1 from live.weather where product = 'ifs_rain' and issued_at = %s limit 1", (run,))
    if cur.fetchone(): print("IFS", run, "already loaded", flush=True); os._exit(0)      # eccodes aborts in interpreter teardown on Linux (double free); leave directly
    rid = start_run(cur, "ecmwf_ifs", "wx_ifs", {"run": run.isoformat()})
    cur.execute("select id, ST_X(ST_PointOnSurface(catchment_geom)), ST_Y(ST_PointOnSurface(catchment_geom)) from geo.waterbody where catchment_geom is not null"); CT = np.array(cur.fetchall())
    LON, LAT = wxlib.image_grid(); prev = None; nf = ncont = 0; crows = []
    for step in range(0, LAST + 1, STEP):
        valid = run + dt.timedelta(hours=step)
        # pressure -> isobars
        v, lat0, lon0, dlat, dlon = field(run, step, "msl"); a, lons, lats = crop(v, lat0, lon0, dlat, dlon, REGION); hpa = a / 100.0
        sm = zoom(hpa, 4, order=3); lo, hi = int(np.floor(sm.min() / 2) * 2), int(np.ceil(sm.max() / 2) * 2); rows = []
        for lvl in range(lo, hi + 1, 2):
            lines = []
            for c in find_contours(sm, lvl):
                if len(c) < 8: continue
                lines.append([(lons[0] + x * (len(lons) - 1) / (sm.shape[1] - 1) * (lons[1] - lons[0]), lats[0] + y * (len(lats) - 1) / (sm.shape[0] - 1) * (lats[1] - lats[0])) for y, x in c])
            if lines: rows.append(("ifs_mslp", run, valid, float(lvl), MultiLineString(lines).wkb))
        # one weather row per step carrying every isobar, as the map draws them: [{l: hPa, g: coordinates}]
        cur.execute("create temp table if not exists stg_ct (lvl real, g bytea)"); cur.execute("truncate stg_ct")
        copy_rows(cur, "stg_ct", ["lvl", "g"], ((r[3], r[4]) for r in rows))
        cur.execute("""insert into live.weather (product, issued_at, valid_at, lines)
                       select 'ifs_mslp', %s, %s, jsonb_agg(jsonb_build_object('l', lvl, 'g', ST_AsGeoJSON(ST_SetSRID(ST_GeomFromWKB(g), 4326), 3)::jsonb -> 'coordinates') order by lvl) from stg_ct
                       on conflict (product, issued_at, valid_at) do update set lines = excluded.lines""", (run, valid))
        ncont += len(rows)
        # rain: accumulation over the previous step -> mm/h
        v, lat0, lon0, dlat, dlon = field(run, step, "tp"); tp, tl, tla = crop(v, lat0, lon0, dlat, dlon, REGION); tp = tp * 1000.0     # m -> mm since start
        if prev is not None:
            rate = np.clip(tp - prev, 0, None) / STEP
            img = sample(rate, tl, tla, LON, LAT); inside = (LON >= tl[0]) & (LON <= tl[-1]) & (LAT >= tla[-1]) & (LAT <= tla[0]); img = np.where(inside, img, np.nan)
            name = f"ifs_{run:%Y%m%d%H}_{step:03d}.png"; fp = os.path.join(wxlib.WX_DIR, "ifs", name); Image.fromarray(wxlib.rain_rgba(img), "RGBA").save(fp, optimize=True); WS.put(f"wx/ifs/{name}", fp)
            if WS.hosted: os.remove(fp)
            cur.execute("insert into live.weather (product, issued_at, valid_at, path, bbox, legend) values ('ifs_rain', %s, %s, %s, %s, %s) on conflict do nothing",
                        (run, valid, f"wx/ifs/{name}", list(wxlib.BBOX), '{"unit":"mm/h","stops":%s,"step_h":%d}' % (list(wxlib.RAIN_STOPS), STEP))); nf += 1
            mm = sample(rate, tl, tla, CT[:, 1], CT[:, 2]) * STEP
            crows += [(int(w), valid, float(m)) for w, m in zip(CT[:, 0], mm)]
        prev = tp; conn.commit(); print("step", step, "h done", flush=True)
    cur.execute("create temp table stg_cr (w bigint, v timestamptz, mm real) on commit drop")
    nc = copy_rows(cur, "stg_cr", ["w", "v", "mm"], crows)
    # this run replaces the previous one: one row per waterbody, steps in order
    cur.execute("""insert into live.rain (waterbody_id, source, issued_at, step_min, at, mm)
                   select w, 'ifs', %s, %s, array_agg(v order by v), array_agg(mm order by v) from stg_cr group by w
                   on conflict (waterbody_id, source) do update set issued_at = excluded.issued_at, step_min = excluded.step_min, at = excluded.at, mm = excluded.mm""", (run, STEP * 60))
    cur.execute("delete from live.weather where product = 'ifs_mslp' and issued_at < %s", (run,))
    cur.execute("delete from live.weather where product = 'ifs_rain' and issued_at < %s returning path", (run,))
    for (p,) in cur.fetchall():
        WS.delete(p)
    finish_run(cur, rid, written=nf + nc + ncont); conn.commit()
    print(f"IFS {run:%Y-%m-%d %Hz}: {nf} rain frames, {ncont} isobars, {nc} catchment values")
    sys.stdout.flush(); os._exit(0)
