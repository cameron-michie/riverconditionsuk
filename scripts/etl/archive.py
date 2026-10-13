"""Cold archive. Readings that fall outside what Postgres keeps leave live.observation for Parquet files laid out like the Storage bucket 'archive':
    observation/<fast|daily|sparse>/year=YYYY/month=MM[/day=DD]/<tag>.parquet      dim/series_<date>.parquet
What Postgres keeps (live.observation):
    fast and daily series (interval up to a day)   the last 7 days
    sparse series (lab samples, bathing water...)  the last 12 readings of each series; citizen-science series also everything from the last 365 days
Order of operations per file: write -> re-read and count -> checksum -> upload -> ledger row (ops.archive_object) -> delete the same rows, all in one transaction, and the
delete must remove exactly the exported rows or the transaction rolls back. Locally files stay in data/archive; hosted, store.py puts them in Supabase Storage.
The archive is write-only for the app: nothing reads it on a schedule except the rare normals rebuild (flow_normal_refresh.py).
Usage: archive.py [--dry-run] [--only observation:daily]"""
import datetime as dt, hashlib, os, sys, time
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
import pyarrow as pa, pyarrow.parquet as pq
from db import connect
import store

ROOT = store.ARCH_DIR; STORE = store.archive()      # local folder, or /tmp scratch with Supabase Storage as the real home
DRY = "--dry-run" in sys.argv
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
HOT_DAYS = 7                 # fast and daily series
SPARSE_KEEP = 12             # readings kept per sparse series
CITIZEN_DAYS = 365           # citizen-science series also keep a year (the volunteer dossier charts it)
CLASS = {"observation:fast": "se.interval_s is not null and se.interval_s < 86400", "observation:daily": "se.interval_s = 86400",
         "observation:sparse": "(se.interval_s is null or se.interval_s > 86400)"}
# the archive's column layout predates the v2 schema; columns live.observation no longer has are written as nulls so every file reads the same
OBS_COLS = ["series_id", "observed_at", "value", "censor", "detection_limit", "value_raw", "quality", "completeness", "sample_id"]
OBS_SEL = ["o.series_id", "o.observed_at", "o.value", "o.censor", "null::float8", "null::text", "o.quality", "null::real", "null::bigint"]
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

def archive_unit(conn, cur, dataset, label, rel, select_sql, delete_sql, params, start, end):
    """one file: export rows, verify, upload, record, delete."""
    cur.execute(select_sql, params); rows = cur.fetchall()
    if not rows: return
    path = os.path.join(ROOT, rel)
    cur.execute("select 1 from ops.archive_object where bucket = 'archive' and path = %s", (rel,))
    if os.path.exists(path) or cur.fetchone(): rel = rel.replace(".parquet", f"-late{int(time.time())}.parquet"); path = os.path.join(ROOT, rel)
    if DRY: print(f"  would archive {len(rows):>9} rows -> {rel}"); totals["rows"] += len(rows); return
    n, size, sha = write_parquet(path, rows, SCHEMA, OBS_COLS)
    if n != len(rows): raise RuntimeError(f"verify failed for {rel}: wrote {n}, read {len(rows)}")
    cur.execute(delete_sql, params)
    if cur.rowcount != n: conn.rollback(); os.remove(path); raise RuntimeError(f"delete would remove {cur.rowcount} rows but {n} were exported ({rel}); rolled back")
    STORE.put(rel, path)                                    # in the bucket before the delete commits
    cur.execute("insert into ops.archive_object (dataset, period_start, period_end, path, rows, bytes, sha256, dropped_at) values (%s,%s,%s,%s,%s,%s,%s, now())", (dataset, start, end, rel, n, size, sha))
    conn.commit(); totals["files"] += 1; totals["rows"] += n
    if STORE.hosted: os.remove(path)
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
    cutoff = (now - dt.timedelta(days=HOT_DAYS)).replace(hour=0, minute=0, second=0, microsecond=0)      # whole UTC days only
    for dataset in ("observation:fast", "observation:daily"):
        if ONLY and dataset != ONLY: continue
        cond = CLASS[dataset]; cls = dataset.split(":")[1]
        print(dataset, f"keeping {HOT_DAYS} d, archiving before {cutoff:%Y-%m-%d}", flush=True)
        cur.execute(f"select min(o.observed_at) from live.observation o join live.series se on se.id = o.series_id where {cond} and o.observed_at < %s", (cutoff,))
        first = cur.fetchone()[0]
        if first is None: print("  nothing to archive"); continue
        for kind, a, b in periods(cutoff.date(), first.date()):
            a_ts = dt.datetime.combine(a, dt.time(), dt.timezone.utc); b_ts = min(dt.datetime.combine(b, dt.time(), dt.timezone.utc), cutoff)
            if a_ts >= b_ts: continue
            rel = f"observation/{cls}/year={a:%Y}/month={a:%m}" + (f"/day={a:%d}" if kind == "day" else "") + f"/{a:%Y%m%d}.parquet"
            sel = f"select {', '.join(OBS_SEL)} from live.observation o join live.series se on se.id = o.series_id where {cond} and o.observed_at >= %s and o.observed_at < %s order by o.series_id, o.observed_at"
            dele = f"delete from live.observation o using live.series se where se.id = o.series_id and {cond} and o.observed_at >= %s and o.observed_at < %s"
            archive_unit(conn, cur, dataset, f"{kind} {a}", rel, sel, dele, (a_ts, b_ts), a_ts, b_ts)
    if not ONLY or ONLY == "observation:sparse":
        dataset = "observation:sparse"
        print(dataset, f"keeping the last {SPARSE_KEEP} readings per series (citizen science: {CITIZEN_DAYS} d)", flush=True)
        cur.execute("drop table if exists _old")
        cur.execute(f"""create temp table _old as
                        select series_id, observed_at from (
                          select o.series_id, o.observed_at, se.evidence_class, row_number() over (partition by o.series_id order by o.observed_at desc) rn
                          from live.observation o join live.series se on se.id = o.series_id where {CLASS[dataset]}) x
                        where rn > %s and not (evidence_class = 'citizen_science' and observed_at > now() - make_interval(days => %s))""", (SPARSE_KEEP, CITIZEN_DAYS))
        cur.execute("create index on _old (series_id, observed_at)")
        cur.execute("select date_trunc('month', observed_at at time zone 'UTC')::date m, count(*) from _old group by 1 order by 1"); months = cur.fetchall()
        conn.commit()
        if not months: print("  nothing to archive")
        for m, _ in months:
            a_ts = dt.datetime.combine(m, dt.time(), dt.timezone.utc); b_ts = dt.datetime.combine((m + dt.timedelta(days=32)).replace(day=1), dt.time(), dt.timezone.utc)
            rel = f"observation/sparse/year={m:%Y}/month={m:%m}/{m:%Y%m%d}.parquet"
            sel = (f"select {', '.join(OBS_SEL)} from live.observation o join _old x on x.series_id = o.series_id and x.observed_at = o.observed_at "
                   "where o.observed_at >= %s and o.observed_at < %s order by o.series_id, o.observed_at")
            dele = "delete from live.observation o using _old x where x.series_id = o.series_id and x.observed_at = o.observed_at and o.observed_at >= %s and o.observed_at < %s"
            archive_unit(conn, cur, dataset, f"month {m}", rel, sel, dele, (a_ts, b_ts), a_ts, b_ts)
    if not DRY and not ONLY and totals["rows"]:
        # dimension snapshot so the archive can be read without the database
        cur.execute("""select se.id, src.slug, se.site_id, s.name, s.kind, ST_X(s.geom), ST_Y(s.geom), p.code, se.unit_id, se.aggregation, se.interval_s, se.source_series_key, se.qualifier
                       from live.series se join ref.source src on src.id = se.source_id join geo.site s on s.id = se.site_id join ref.parameter p on p.id = se.parameter_id""")
        rows = cur.fetchall(); names = ["series_id", "source", "site_id", "site_name", "site_kind", "lon", "lat", "parameter", "unit", "aggregation", "interval_s", "source_series_key", "qualifier"]
        os.makedirs(os.path.join(ROOT, "dim"), exist_ok=True)
        dim = os.path.join(ROOT, "dim", f"series_{now:%Y%m%d}.parquet"); pq.write_table(pa.table({n: [r[i] for r in rows] for i, n in enumerate(names)}), dim, compression="zstd")
        STORE.put(f"dim/series_{now:%Y%m%d}.parquet", dim)
        if STORE.hosted: os.remove(dim)
    print(f"{'would archive' if DRY else 'archived'} {totals['rows']:,} rows in {totals['files']} files")
if not DRY and totals["rows"]:
    c = connect(); c.autocommit = True
    with c.cursor() as cur: cur.execute("vacuum (analyze) live.observation")
    c.close()
