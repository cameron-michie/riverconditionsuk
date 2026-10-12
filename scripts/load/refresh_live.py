"""Bring 'now' up to date: latest gauge readings, overflow statuses, flood warnings, then rebuild gauge flood state. Safe to run every 15 minutes."""
import datetime as dt, os, sys, time
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "collect")]
import lib
from db import *
t0 = time.time()
FLOOD = "https://environment.data.gov.uk/flood-monitoring"
with connect() as conn, conn.cursor() as cur:
    # ── 1. latest readings from every station (one call)
    j = lib.getj(f"{FLOOD}/data/readings", params={"latest": "", "_limit": 100000}, timeout=300)["items"]
    cur.execute("select source_series_key, id from core.series where source_id = (select id from ingest.source where slug='ea_flood_monitoring')"); SER = dict(cur.fetchall())
    cur.execute("select unit_id, 1 from core.series group by 1")
    cur.execute("select s.source_series_key, u.factor, u.\"offset\" from core.series s join ref.unit u on u.id = s.unit_id where s.source_id = (select id from ingest.source where slug='ea_flood_monitoring')"); CONV = {k: (float(f), float(o)) for k, f, o in cur.fetchall()}
    rows = []
    for r in j:
        key = r["measure"].rsplit("/", 1)[-1]; sid = SER.get(key)
        v = r.get("value"); v = v[0] if isinstance(v, list) and v else v
        if sid is None or not isinstance(v, (int, float)): continue
        f, o = CONV[key]; rows.append((sid, r["dateTime"], v * f + o))
    cur.execute("create temp table stg_r (sid bigint, at timestamptz, v float8) on commit drop"); copy_rows(cur, "stg_r", ["sid", "at", "v"], rows)
    cur.execute("insert into core.observation (series_id, observed_at, value, quality) select sid, at, v, 'unchecked' from stg_r on conflict do nothing")
    cur.execute("""insert into core.observation_latest (series_id, observed_at, value, quality) select distinct on (sid) sid, at, v, 'unchecked' from stg_r order by sid, at desc
                   on conflict (series_id) do update set observed_at = excluded.observed_at, value = excluded.value, quality = excluded.quality, updated_at = now() where excluded.observed_at > core.observation_latest.observed_at""")
    print("readings", len(rows), "of", len(j), round(time.time() - t0, 1), "s")
    # ── 2. overflow statuses (English company feeds share one schema; Scottish Water has its own)
    import sewage_feeds
    cur.execute("select value, site_id from core.site_identifier where scheme = 'nsoh:id'"); NS = dict(cur.fetchall())
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
    cur.execute("""insert into core.overflow_status (site_id, status, raw_status, status_since, last_event_start, last_event_end, reported_at, fetched_at, source_id)
        select sid, st, raw, since::timestamptz, ls::timestamptz, le::timestamptz, rep::timestamptz, now(), src from stg_o
        on conflict (site_id) do update set status = excluded.status, raw_status = excluded.raw_status, status_since = excluded.status_since, last_event_start = excluded.last_event_start,
                                            last_event_end = excluded.last_event_end, reported_at = excluded.reported_at, fetched_at = excluded.fetched_at""")
    cur.execute("select count(*) filter (where status = 'discharging') from core.overflow_status"); print("overflow statuses", len(out), "discharging now:", cur.fetchone()[0], round(time.time() - t0, 1), "s")
    # ── 3. flood state
    cur.execute("select core.refresh_gauge_state()"); cur.execute("select core.refresh_flow_signals()"); cur.execute("select band, count(*) from core.gauge_state group by 1 order by 2 desc"); print("gauge bands", cur.fetchall())
    cur.execute("select core.refresh_sewage_works()")
    conn.commit()
# ── 4. warnings and the five-day outlook (separate collector + loader)
import subprocess
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
env = dict(os.environ, PYTHONPATH=root)
subprocess.run([sys.executable, "-W", "ignore", "flood_forecast.py"], cwd=os.path.join(root, "collect"), env=env, check=False, capture_output=True)
subprocess.run([sys.executable, "-W", "ignore", "load_flood.py"], cwd=os.path.dirname(os.path.abspath(__file__)), env=env, check=False, capture_output=True)
subprocess.run([sys.executable, "-W", "ignore", "refresh_flood_zones.py"], cwd=os.path.dirname(os.path.abspath(__file__)), env=env, check=False, capture_output=True)
print("done", round(time.time() - t0, 1), "s")
