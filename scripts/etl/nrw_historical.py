"""NRW Rivers and Seas API (key in .env, NRW_RIVERS_SEAS_KEY): a year of 15-minute river level and rainfall for ~400 Welsh stations.
  nrw_historical.py            backfill: last 8 days -> Postgres, everything older -> Parquet archive (once; refuses to run twice)
  nrw_historical.py --days N   gap fill: last N days -> Postgres only (use after an outage)
Stations are the same gauges as the open telemetry API, with coordinates that differ by ~90 m, so they are matched by position (<= 400 m) and kind."""
import concurrent.futures as cf, datetime as dt, hashlib, json, math, os, sys
import common, lib
from common import upsert_obs
from db import connect, source_id, start_run, finish_run
import pyarrow as pa, pyarrow.parquet as pq

for line in open(os.path.join(lib.ROOT, "..", "..", ".env")):
    if "=" in line and not line.startswith("#"): k, v = line.strip().split("=", 1); os.environ.setdefault(k, v)
H = {"Ocp-Apim-Subscription-Key": os.environ["NRW_RIVERS_SEAS_KEY"]}; B = "https://api.naturalresources.wales/rivers-and-seas/v1/api/"
ARCH = os.path.abspath(os.path.join(lib.ROOT, "..", "archive"))
KIND = {"River Level": ("water_level", "river_gauge", "instant"), "Rainfall": ("rainfall", "rain_gauge", "sum")}
days = int(sys.argv[sys.argv.index("--days") + 1]) if "--days" in sys.argv else None
now = dt.datetime.now(dt.timezone.utc); hot_from = now - dt.timedelta(days=days or 8)
SCHEMA = pa.schema([("series_id", pa.int64()), ("observed_at", pa.timestamp("us", tz="UTC")), ("value", pa.float64()), ("censor", pa.string()), ("detection_limit", pa.float64()),
                    ("value_raw", pa.string()), ("quality", pa.string()), ("completeness", pa.float32()), ("sample_id", pa.int64())])
dist = lambda a, b: math.hypot((a[0] - b[0]) * 69000, (a[1] - b[1]) * 111000)

with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "nrw_river_levels"); run = start_run(cur, "nrw_river_levels", "nrw_historical", {"days": days})
    if days is None:
        cur.execute("select count(*) from ops.archive_object where path like '%nrw_hist_%'")
        if cur.fetchone()[0]: sys.exit("history already archived; use --days N to fill a recent gap")
    stations = lib.get(B + "StationData", headers=H).json()
    cur.execute("select s.id, s.kind, ST_X(s.geom), ST_Y(s.geom) from core.site s join core.site_identifier i on i.site_id = s.id and i.scheme = 'nrw:station'"); TEL = cur.fetchall()
    cur.execute("select value, site_id from core.site_identifier where scheme = 'nrw:rs'"); RS = dict(cur.fetchall())
    cur.execute("select code, id from ref.parameter"); PID = dict(cur.fetchall())
    cur.execute("select se.site_id, se.parameter_id, se.id from core.series se where se.source_id = %s and se.interval_s = 900", (S,)); SERIES = {(a, b): c for a, b, c in cur.fetchall()}
    taken, jobs = set(RS.values()), []
    for st in stations:
        loc = str(st["location"]); pos = (st["longitude"], st["latitude"])
        for p in st["parameters"]:
            if p["paramNameEN"] not in KIND: continue
            code, kind, agg = KIND[p["paramNameEN"]]
            if loc not in RS:
                c = sorted((dist((x, y), pos), sid) for sid, k, x, y in TEL if k == kind and sid not in taken)
                if c and c[0][0] <= 400: sid = c[0][1]
                else:
                    cur.execute("""insert into core.site (kind, name, geom, geom_bng, country, status, primary_source_id, attrs) values (%s, %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326),
                                   ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700), 'WLS', 'active', %s, %s) returning id""", (kind, st["titleEn"] or st["nameEN"], *pos, *pos, S, json.dumps({"nrw_rs": loc})))
                    sid = cur.fetchone()[0]
                cur.execute("insert into core.site_identifier (scheme, value, site_id, source_id, match_method) values ('nrw:rs', %s, %s, %s, 'spatial') on conflict do nothing", (loc, sid, S))
                RS[loc] = sid; taken.add(sid)
            site = RS[loc]; key = (site, PID[code])
            if key not in SERIES:
                cur.execute("""insert into core.series (site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, qualifier, datum, evidence_class)
                               values (%s, %s, %s, %s, %s, 900, 'm', %s, %s, %s, 'official_monitoring') on conflict do nothing returning id""",
                            (site, PID[code], S, f"nrw_rs:{loc}:{p['parameter']}", agg, p["units"], "stage" if code == "water_level" else "15min_total", p["units"] if p["units"] == "mAOD" else None))
                x = cur.fetchone()
                if x is None: continue
                if code == "rainfall": cur.execute("update core.series set unit_id = 'mm' where id = %s", (x[0],))
                SERIES[key] = x[0]
            jobs.append((loc, p["parameter"], SERIES[key]))
    conn.commit(); print(len(stations), "stations,", len(jobs), "series to fetch", flush=True)

    def fetch(j):
        loc, par, sid = j
        try: r = lib.get(f"{B}StationData/historical", params={"location": loc, "parameter": par}, headers=H, timeout=180).json()
        except Exception as e: return sid, None
        return sid, [(sid, dt.datetime.fromisoformat(x["time"].replace("Z", "+00:00")), float(x["value"])) for x in r.get("parameterReadings", []) if x.get("value") is not None]
    RAIN_SIDS = {v for (_, p), v in SERIES.items() if p == PID['rainfall']}
    hot, old, bad = [], [], 0
    with cf.ThreadPoolExecutor(6) as ex:
        for i, (sid, rows) in enumerate(ex.map(fetch, jobs)):
            if rows is None: bad += 1; continue
            cap = 200 if sid in RAIN_SIDS else 1e9               # a rain gauge cannot tip 200 mm in 15 minutes
            for r in rows:
                if r[2] < 0 or r[2] > cap: continue
                (hot if r[1] >= hot_from else old).append(r)
            if i % 100 == 99: print(i + 1, "of", len(jobs), len(hot), "hot,", len(old), "old rows", flush=True)
    a, b = upsert_obs(cur, [(s, t, v, "unchecked", None) for s, t, v in hot], update=False)
    print(f"hot window: {a} readings, {b} new")
    files = 0
    if days is None:
        by_month = {}
        for r in old: by_month.setdefault((r[1].year, r[1].month), []).append(r)
        for (y, m), rs in sorted(by_month.items()):
            rs.sort(key=lambda r: (r[0], r[1])); rel = f"observation/fast/year={y}/month={m:02d}/nrw_hist_{now:%Y%m%d}.parquet"; path = os.path.join(ARCH, rel); os.makedirs(os.path.dirname(path), exist_ok=True)
            cols = [[r[0] for r in rs], [r[1] for r in rs], [r[2] for r in rs]]
            t = pa.table({"series_id": pa.array(cols[0], pa.int64()), "observed_at": pa.array(cols[1], pa.timestamp("us", tz="UTC")), "value": pa.array(cols[2], pa.float64()),
                          "censor": pa.nulls(len(rs), pa.string()), "detection_limit": pa.nulls(len(rs), pa.float64()), "value_raw": pa.nulls(len(rs), pa.string()),
                          "quality": pa.array(["unchecked"] * len(rs), pa.string()), "completeness": pa.nulls(len(rs), pa.float32()), "sample_id": pa.nulls(len(rs), pa.int64())}, schema=SCHEMA)
            pq.write_table(t, path, compression="zstd"); n = pq.read_metadata(path).num_rows; assert n == len(rs)
            cur.execute("""insert into ops.archive_object (dataset, period_start, period_end, path, rows, bytes, sha256, dropped_at) values ('observation:fast', %s, %s, %s, %s, %s, %s, now())
                           on conflict (bucket, path) do update set rows = excluded.rows, bytes = excluded.bytes, sha256 = excluded.sha256""",
                        (dt.datetime(y, m, 1, tzinfo=dt.timezone.utc), (dt.datetime(y, m, 28, tzinfo=dt.timezone.utc) + dt.timedelta(days=5)).replace(day=1), rel, n, os.path.getsize(path), hashlib.sha256(open(path, "rb").read()).hexdigest()))
            files += 1
        print(f"archived {len(old):,} older readings in {files} files")
    cur.execute("select ops.flag_implausible(now() - interval '9 days')")
    finish_run(cur, run, read=len(hot) + len(old), written=b + len(old), rejected=bad); conn.commit()
    print(f"done: {len(jobs)} series, {bad} failed")
