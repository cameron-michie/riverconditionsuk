"""Bring 'now' up to date: latest gauge readings, overflow statuses, flood warnings, then rebuild gauge flood state. Safe to run every 15 minutes."""
import datetime as dt, os, sys, time
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "collect")]
import lib
from db import *
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "etl")); import common
t0 = time.time()
FLOOD = "https://environment.data.gov.uk/flood-monitoring"
with connect() as conn, conn.cursor() as cur:
    # ── 1. latest readings from every station (one call)
    j = lib.getj(f"{FLOOD}/data/readings", params={"latest": "", "_limit": 100000}, timeout=300)["items"]
    cur.execute("select source_series_key, id from live.series where source_id = (select id from ref.source where slug='ea_flood_monitoring')"); SER = dict(cur.fetchall())
    cur.execute("select s.source_series_key, u.factor, u.\"offset\" from live.series s join ref.unit u on u.id = s.unit_id where s.source_id = (select id from ref.source where slug='ea_flood_monitoring')"); CONV = {k: (float(f), float(o)) for k, f, o in cur.fetchall()}
    rows = []
    for r in j:
        key = r["measure"].rsplit("/", 1)[-1]; sid = SER.get(key)
        v = r.get("value"); v = v[0] if isinstance(v, list) and v else v
        if sid is None or not isinstance(v, (int, float)): continue
        f, o = CONV[key]; rows.append((sid, r["dateTime"], v * f + o))
    cur.execute("create temp table stg_r (sid bigint, at timestamptz, v float8) on commit drop"); copy_rows(cur, "stg_r", ["sid", "at", "v"], rows)
    cur.execute("create temp table stg_rl on commit drop as select sid series_id, at observed_at, v value, 'unchecked'::text quality, null::text censor from stg_r")
    common.merge_staged(cur, "stg_rl", update=False)
    print("readings", len(rows), "of", len(j), round(time.time() - t0, 1), "s")
    cur.execute("select live.flag_implausible(now() - interval '3 hours')"); print("flagged implausible", cur.fetchone()[0])
    # ── 2. overflow statuses (English company feeds share one schema; Scottish Water has its own)
    import sewage_feeds
    cur.execute("select value, site_id from geo.site_key where scheme = 'nsoh:id'"); NS = dict(cur.fetchall())
    S_ENG = source_id(cur, "nsoh_england"); S_SCO = source_id(cur, "nsoh_scotland"); MAP = {1: "discharging", 0: "not_discharging", -1: "offline"}
    ms = lambda v: dt.datetime.fromtimestamp(v / 1000, dt.timezone.utc).isoformat() if isinstance(v, (int, float)) and v > 0 else None
    out = {}
    for name, url in {**sewage_feeds.FEEDS, **{k: u for k, u in sewage_feeds.EXTRA.items() if k != "scottish_water_sepa_live"}}.items():
        try: feats, _ = lib.arcgis_all(url)
        except Exception as e: print("feed failed", name, str(e)[:80]); continue
        for f in feats:
            p = f["properties"]; scot = "ASSET_ID" in p; sid = NS.get(p.get("ASSET_ID") if scot else (p.get("Id") or p.get("id")))
            if not sid: continue
            g = lambda k: p.get(k) if k in p else p.get(k[0].lower() + k[1:])
            if scot: out[sid] = (MAP.get(p.get("STATUS_NSOH"), "unknown"), str(p.get("STATUS_NSOH")), None, None, None, p.get("LAST_TRANSMITTED_DATETIME") or None, S_SCO)
            else: out[sid] = (MAP.get(g("Status"), "unknown"), str(g("Status")), ms(g("StatusStart")), ms(g("LatestEventStart")), ms(g("LatestEventEnd")), ms(g("LastUpdated")), S_ENG)
    cur.execute("create temp table stg_o (sid bigint, st text, raw text, since text, ls text, le text, rep text, src bigint) on commit drop")
    copy_rows(cur, "stg_o", ["sid", "st", "raw", "since", "ls", "le", "rep", "src"], ((k, *v) for k, v in out.items()))
    cur.execute("""insert into live.site_now (site_id, kind, state, since, at, detail)
        select sid, 'overflow', st, since::timestamptz, rep::timestamptz,
               jsonb_strip_nulls(jsonb_build_object('raw_status', raw, 'last_event_start', ls::timestamptz, 'last_event_end', le::timestamptz, 'source_id', src)) from stg_o
        on conflict (site_id) do update set state = excluded.state, since = excluded.since, at = excluded.at, detail = excluded.detail, updated_at = now()""")
    cur.execute("select count(*) filter (where state = 'discharging') from live.site_now where kind = 'overflow'"); print("overflow statuses", len(out), "discharging now:", cur.fetchone()[0], round(time.time() - t0, 1), "s")
    # ── 3. flood state
    cur.execute("select live.refresh_gauges()"); cur.execute("select live.refresh_flow_signals()"); cur.execute("select state, count(*) from live.site_now where kind = 'gauge' group by 1 order by 2 desc"); print("gauge bands", cur.fetchall())
    cur.execute("select live.refresh_works()")
    conn.commit()
# ── 4. warnings and the five-day outlook (separate collector + loader)
import subprocess
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
env = dict(os.environ, PYTHONPATH=root); here = os.path.dirname(os.path.abspath(__file__)); failed = []
for script, cwd in (("flood_forecast.py", os.path.join(root, "collect")), ("load_flood.py", here), ("refresh_flood_zones.py", here)):
    p = subprocess.run([sys.executable, "-W", "ignore", script], cwd=cwd, env=env, capture_output=True, text=True)
    if p.returncode: failed.append(script); print("FAILED", script, (p.stderr or p.stdout)[-400:])
print("done", round(time.time() - t0, 1), "s")
if failed: sys.exit(1)
