"""Met Office UK radar: new 15-minute frames -> map PNG (live.weather) + catchment-average rain (live.rain, appended per waterbody). Keeps 3 h of frames.
Usage: wx_radar.py [hours_back]   (default 3; use 48 once to backfill catchment rain)"""
import datetime as dt, os, re, sys, tempfile
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load"), os.path.dirname(os.path.abspath(__file__))]
import h5py, numpy as np
from PIL import Image
import lib, wxlib
from db import connect, copy_rows, source_id, start_run, finish_run
import store
WS = store.weather()

BUCKET = "https://met-office-radar-obs-data.s3.eu-west-2.amazonaws.com"
KEEP_FRAMES_H = 3
hours = int(sys.argv[1]) if len(sys.argv) > 1 else 3
now = dt.datetime.now(dt.timezone.utc)

def keys_since(t0):
    out, d = [], t0.date()
    while d <= now.date():
        r = lib.get(f"{BUCKET}/?list-type=2&prefix=radar/{d:%Y/%m/%d}/").text
        for k in re.findall(r"<Key>([^<]+)", r):
            m = re.search(r"/(\d{12})_ODIM", k)
            if m:
                t = dt.datetime.strptime(m.group(1), "%Y%m%d%H%M").replace(tzinfo=dt.timezone.utc)
                if t >= t0: out.append((t, k))
        d += dt.timedelta(days=1)
    return sorted(out)

LON, LAT = wxlib.image_grid(); CX, CY = wxlib.lonlat_to_cell(LON, LAT)
INSIDE = (CX >= 0) & (CX < wxlib.RADAR_SHAPE[1]) & (CY >= 0) & (CY < wxlib.RADAR_SHAPE[0])
os.makedirs(os.path.join(wxlib.WX_DIR, "radar"), exist_ok=True)

with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "metoffice_radar"); run = start_run(cur, "metoffice_radar", "wx_radar", {"hours": hours})
    cur.execute("select valid_at from live.weather where product = 'radar_rain'"); have_f = {r[0] for r in cur.fetchall()}
    cur.execute("select distinct u.t from live.rain r cross join lateral unnest(r.at) u(t) where r.source = 'radar' and u.t > now() - make_interval(hours => %s)", (hours + 1,)); have_c = {r[0] for r in cur.fetchall()}
    cur.execute("select w.id, c / 10000, c % 10000 from geo.waterbody w cross join lateral unnest(w.radar_cells) c order by w.id"); cc = np.array(cur.fetchall())
    wids, inv = np.unique(cc[:, 0], return_inverse=True)
    frames = rain = 0
    for t, key in keys_since(now - dt.timedelta(hours=hours)):
        need_f = t not in have_f and t > now - dt.timedelta(hours=KEEP_FRAMES_H); need_c = t not in have_c
        if not (need_f or need_c): continue
        try: raw = lib.get(f"{BUCKET}/{key}").content
        except Exception as e: print("skip", key, str(e)[:80]); continue
        with tempfile.NamedTemporaryFile(suffix=".h5") as f:
            f.write(raw); f.flush()
            with h5py.File(f.name) as h: rate = h["dataset1/data1/data"][...].astype("float32")
        rate[rate < 0] = np.nan      # nodata (outside radar cover)
        if need_f:
            img = np.full(LON.shape, np.nan, dtype="float32"); img[INSIDE] = rate[CY[INSIDE], CX[INSIDE]]
            name = f"radar_{t:%Y%m%d%H%M}.png"; fp = os.path.join(wxlib.WX_DIR, "radar", name); Image.fromarray(wxlib.rain_rgba(img), "RGBA").save(fp, optimize=True); WS.put(f"wx/radar/{name}", fp)
            if WS.hosted: os.remove(fp)
            cur.execute("""insert into live.weather (product, issued_at, valid_at, path, bbox, legend) values ('radar_rain', %s, %s, %s, %s, %s)
                           on conflict do nothing""", (t, t, f"wx/radar/{name}", list(wxlib.BBOX), '{"unit":"mm/h","stops":%s}' % list(wxlib.RAIN_STOPS))); frames += 1
        if need_c:
            v = rate[cc[:, 2], cc[:, 1]]; ok = np.isfinite(v)
            tot = np.bincount(inv[ok], weights=v[ok], minlength=len(wids)); n = np.bincount(inv[ok], minlength=len(wids))
            mm = np.where(n > 0, tot / np.maximum(n, 1) / 4, np.nan)       # mm/h averaged over catchment cells -> mm in the 15 min step
            rows = [(int(w), t, float(m)) for w, m in zip(wids, mm) if np.isfinite(m)]
            cur.execute("create temp table stg_cr (w bigint, v timestamptz, mm real) on commit drop")
            copy_rows(cur, "stg_cr", ["w", "v", "mm"], rows)
            # append this step to each waterbody's radar arrays, once (live.trim() drops steps older than 8 days)
            cur.execute("""insert into live.rain (waterbody_id, source, issued_at, step_min, at, mm) select w, 'radar', v, 15, array[v], array[mm] from stg_cr
                           on conflict (waterbody_id, source) do update set at = live.rain.at || excluded.at, mm = live.rain.mm || excluded.mm,
                                                                            issued_at = greatest(live.rain.issued_at, excluded.issued_at)
                           where not (excluded.at[1] = any(live.rain.at))"""); rain += len(rows)
        conn.commit()
    # expire old frames (image files and rows)
    cur.execute("delete from live.weather where product = 'radar_rain' and valid_at < now() - make_interval(hours => %s) returning path", (KEEP_FRAMES_H,))
    for (p,) in cur.fetchall():
        WS.delete(p)
    finish_run(cur, run, written=frames + rain); conn.commit()
    print(f"radar: {frames} new frames, {rain} catchment values")
