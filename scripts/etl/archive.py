"""Cold archive. Rows older than their retention (ops.retention_rule) leave Postgres for Parquet files laid out like the Storage bucket 'archive':
    observation/<fast|daily|sparse>/year=YYYY/month=MM[/day=DD]/<tag>.parquet      wx/catchment_rain/year=YYYY/month=MM/day=DD/<tag>.parquet      dim/series_<date>.parquet
Order of operations per file: write -> re-read and count -> checksum -> ledger row (ops.archive_object) -> delete the same rows, all in one transaction, and the delete
must remove exactly the exported rows or the transaction rolls back. Locally files go to data/archive; archive_sync.py pushes them to Supabase Storage.
Usage: archive.py [--dry-run] [--only observation:daily]"""
import datetime as dt, hashlib, os, sys, time
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
import pyarrow as pa, pyarrow.parquet as pq
from db import connect

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "archive"))
DRY = "--dry-run" in sys.argv
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
CLASS = {"observation:fast": "se.interval_s is not null and se.interval_s < 86400", "observation:daily": "se.interval_s = 86400",
         "observation:sparse": "(se.interval_s is null or se.interval_s > 86400)"}
OBS_COLS = ["series_id", "observed_at", "value", "censor", "detection_limit", "value_raw", "quality", "completeness", "sample_id"]
SCHEMA = pa.schema([("series_id", pa.int64()), ("observed_at", pa.timestamp("us", tz="UTC")), ("value", pa.float64()), ("censor", pa.string()), ("detection_limit", pa.float64()),
                    ("value_raw", pa.string()), ("quality", pa.string()), ("completeness", pa.float32()), ("sample_id", pa.int64())])
now = dt.datetime.now(dt.timezone.utc)
totals = {"files": 0, "rows": 0}

def write_parquet(path, rows, schema, cols):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    arrays = [pa.array([r[i] for r in rows], type=schema.field(i).type) for i in range(len(cols))]
    pq.write_table(pa.Table.from_arrays(arrays, schema=schema), path + ".tmp", compression="zstd")
    os.replace(path + ".tmp", path)
    n = pq.read_metadata(path).num_rows
    sha = hashlib.sha256(open(path, "rb").read()).hexdigest()
    return n, os.path.getsize(path), sha

def archive_unit(conn, cur, dataset, label, rel, select_sql, delete_sql, params, start, end, schema, cols):
    """one file: export rows, verify, record, delete."""
    cur.execute(select_sql, params); rows = cur.fetchall()
    if not rows: return
    path = os.path.join(ROOT, rel)
    if os.path.exists(path): rel = rel.replace(".parquet", f"-late{int(time.time())}.parquet"); path = os.path.join(ROOT, rel)
    if DRY: print(f"  would archive {len(rows):>9} rows -> {rel}"); totals["rows"] += len(rows); return
    n, size, sha = write_parquet(path, rows, schema, cols)
    if n != len(rows): raise RuntimeError(f"verify failed for {rel}: wrote {n}, read {len(rows)}")
    cur.execute("insert into ops.archive_object (dataset, period_start, period_end, path, rows, bytes, sha256, dropped_at) values (%s,%s,%s,%s,%s,%s,%s, now())", (dataset, start, end, rel, n, size, sha))
    cur.execute(delete_sql, params)
    if cur.rowcount != n: conn.rollback(); os.remove(path); raise RuntimeError(f"delete removed {cur.rowcount} rows but {n} were archived ({rel}); rolled back")
    conn.commit(); totals["files"] += 1; totals["rows"] += n
    print(f"  {dataset} {label}: {n:>9} rows, {size / 1e6:6.1f} MB -> {rel}", flush=True)

def periods(cutoff, first):
    """cutoff, first: dates. Monthly units for complete months before the cutoff's month, daily units from the start of that month up to the cutoff."""
    m = first.replace(day=1); cm = cutoff.replace(day=1)
    while m < cm:
        nxt = (m + dt.timedelta(days=32)).replace(day=1); yield "month", m, nxt; m = nxt
    d = cm
    while d < cutoff:
        yield "day", d, d + dt.timedelta(days=1); d += dt.timedelta(days=1)

with connect() as conn, conn.cursor() as cur:
    cur.execute("select dataset, hot_days from ops.retention_rule"); RULES = dict(cur.fetchall())
    for dataset, hot in RULES.items():
        if ONLY and dataset != ONLY: continue
        cutoff = (now - dt.timedelta(days=hot)).replace(hour=0, minute=0, second=0, microsecond=0)      # whole UTC days only
        print(dataset, f"hot {hot} d, archiving before {cutoff:%Y-%m-%d}", flush=True)
        if dataset in CLASS:
            cond = CLASS[dataset]; cls = dataset.split(":")[1]
            cur.execute(f"select min(o.observed_at) from core.observation o join core.series se on se.id = o.series_id where {cond} and o.observed_at < %s", (cutoff,))
            first = cur.fetchone()[0]
            if first is None: print("  nothing to archive"); continue
            for kind, a, b in periods(cutoff.date(), first.date()):
                a_ts = dt.datetime.combine(a, dt.time(), dt.timezone.utc); b_ts = min(dt.datetime.combine(b, dt.time(), dt.timezone.utc), cutoff)
                if a_ts >= b_ts: continue
                tag = f"{a:%Y%m%d}"; rel = f"observation/{cls}/year={a:%Y}/month={a:%m}" + (f"/day={a:%d}" if kind == "day" else "") + f"/{tag}.parquet"
                sel = f"select {', '.join('o.' + c for c in OBS_COLS)} from core.observation o join core.series se on se.id = o.series_id where {cond} and o.observed_at >= %s and o.observed_at < %s order by o.series_id, o.observed_at"
                dele = f"delete from core.observation o using core.series se where se.id = o.series_id and {cond} and o.observed_at >= %s and o.observed_at < %s"
                archive_unit(conn, cur, dataset, f"{kind} {a}", rel, sel, dele, (a_ts, b_ts), a_ts, b_ts, SCHEMA, OBS_COLS)
        elif dataset == "wx:catchment_rain":
            cur.execute("select min(valid_at) from wx.catchment_rain where valid_at < %s", (cutoff,)); first = cur.fetchone()[0]
            if first is None: print("  nothing to archive"); continue
            sch = pa.schema([("waterbody_id", pa.int64()), ("source", pa.string()), ("issued_at", pa.timestamp("us", tz="UTC")), ("valid_at", pa.timestamp("us", tz="UTC")), ("mm", pa.float32()), ("step_min", pa.int16())])
            cols = ["waterbody_id", "source", "issued_at", "valid_at", "mm", "step_min"]; d = first.date()
            while d < cutoff.date():
                a_ts = dt.datetime.combine(d, dt.time(), dt.timezone.utc); b_ts = a_ts + dt.timedelta(days=1)
                archive_unit(conn, cur, dataset, str(d), f"wx/catchment_rain/year={d:%Y}/month={d:%m}/day={d:%d}/{d:%Y%m%d}.parquet",
                             f"select {', '.join(cols)} from wx.catchment_rain where valid_at >= %s and valid_at < %s order by waterbody_id, valid_at",
                             "delete from wx.catchment_rain where valid_at >= %s and valid_at < %s", (a_ts, b_ts), a_ts, b_ts, sch, cols)
                d += dt.timedelta(days=1)
    if not DRY and not ONLY:
        # dimension snapshot so the archive can be read without the database
        cur.execute("""select se.id, src.slug, se.site_id, s.name, s.kind, ST_X(s.geom), ST_Y(s.geom), p.code, se.unit_id, se.aggregation, se.interval_s, se.source_series_key, se.qualifier
                       from core.series se join ingest.source src on src.id = se.source_id join core.site s on s.id = se.site_id join ref.parameter p on p.id = se.parameter_id""")
        rows = cur.fetchall(); names = ["series_id", "source", "site_id", "site_name", "site_kind", "lon", "lat", "parameter", "unit", "aggregation", "interval_s", "source_series_key", "qualifier"]
        os.makedirs(os.path.join(ROOT, "dim"), exist_ok=True)
        pq.write_table(pa.table({n: [r[i] for r in rows] for i, n in enumerate(names)}), os.path.join(ROOT, "dim", f"series_{now:%Y%m%d}.parquet"), compression="zstd")
    print(f"{'would archive' if DRY else 'archived'} {totals['rows']:,} rows in {totals['files']} files")
if not DRY and totals["rows"]:
    c = connect(); c.autocommit = True
    with c.cursor() as cur:
        for t in ("core.observation", "wx.catchment_rain"): cur.execute(f"vacuum (analyze) {t}")
    c.close()
