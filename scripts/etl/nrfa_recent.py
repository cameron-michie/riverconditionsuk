"""NRFA quality-controlled daily mean flow (gdf), values newer than what we hold. NRFA publishes about 30 days behind, so these rows are archive-age on arrival:
they go straight to the Parquet archive (and ledger), not through Postgres. The weekly flow_normal rebuild reads them from there."""
import concurrent.futures as cf, datetime as dt, glob, hashlib, os, sys
import common, lib
import pyarrow as pa, pyarrow.dataset as ds, pyarrow.parquet as pq
from db import connect, source_id, start_run, finish_run

B = "https://nrfaapps.ceh.ac.uk/nrfa/ws"
ARCH = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "archive"))
SCHEMA = pa.schema([("series_id", pa.int64()), ("observed_at", pa.timestamp("us", tz="UTC")), ("value", pa.float64()), ("censor", pa.string()), ("detection_limit", pa.float64()),
                    ("value_raw", pa.string()), ("quality", pa.string()), ("completeness", pa.float32()), ("sample_id", pa.int64())])
with connect() as conn, conn.cursor() as cur:
    S = source_id(cur, "nrfa"); run = start_run(cur, "nrfa", "nrfa_recent")
    cur.execute("select s.source_series_key, s.id from core.series s where s.source_id = %s and s.qualifier = 'gdf'", (S,)); SER = {k.split(":")[1]: i for k, i in cur.fetchall()}     # nrfa:<id>:gdf
    cur.execute("select series_id, max(observed_at) from core.observation where series_id = any(%s) group by 1", (list(SER.values()),)); last = dict(cur.fetchall())
    d_dir = os.path.join(ARCH, "observation", "daily")
    if glob.glob(os.path.join(d_dir, "**", "*.parquet"), recursive=True):
        t = ds.dataset(d_dir, format="parquet", partitioning="hive").to_table(columns=["series_id", "observed_at"], filter=ds.field("series_id").isin(list(SER.values()))).to_pandas()
        for sid, m in t.groupby("series_id").observed_at.max().items():
            if sid not in last or m > last[sid]: last[sid] = m
    def one(item):
        nid, sid = item; since = (last[sid] - dt.timedelta(days=3)).date().isoformat() if sid in last else "2015-01-01"
        try: j = lib.get(f"{B}/time-series", params={"station": nid, "data-type": "gdf", "format": "json-object", "start": since}).json()["data-stream"]
        except Exception: return sid, []
        return sid, [(sid, dt.datetime.fromisoformat(j[i]).replace(tzinfo=dt.timezone.utc), float(j[i + 1]), None, None, None, "good", None, None)
                     for i in range(0, len(j) - 1, 2) if j[i + 1] is not None and (sid not in last or dt.datetime.fromisoformat(j[i]).replace(tzinfo=dt.timezone.utc) > last[sid])]
    rows = []
    with cf.ThreadPoolExecutor(6) as ex:
        for sid, r in ex.map(one, SER.items()): rows += r
    print(len(rows), "new daily flows from", len({r[0] for r in rows}), "gauges", flush=True)
    by_month = {}
    for r in rows: by_month.setdefault((r[1].year, r[1].month), []).append(r)
    for (y, m), rs in sorted(by_month.items()):
        rel = f"observation/daily/year={y}/month={m:02d}/nrfa_{dt.date.today():%Y%m%d}.parquet"; path = os.path.join(ARCH, rel); os.makedirs(os.path.dirname(path), exist_ok=True)
        pq.write_table(pa.Table.from_arrays([pa.array([r[i] for r in rs], type=SCHEMA.field(i).type) for i in range(9)], schema=SCHEMA), path, compression="zstd")
        n = pq.read_metadata(path).num_rows; assert n == len(rs)
        cur.execute("""insert into ops.archive_object (dataset, period_start, period_end, path, rows, bytes, sha256, dropped_at) values ('observation:daily', %s, %s, %s, %s, %s, %s, now())
                       on conflict (bucket, path) do update set rows = excluded.rows, bytes = excluded.bytes, sha256 = excluded.sha256""",
                    (dt.datetime(y, m, 1, tzinfo=dt.timezone.utc), (dt.datetime(y, m, 28, tzinfo=dt.timezone.utc) + dt.timedelta(days=5)).replace(day=1), rel, n, os.path.getsize(path), hashlib.sha256(open(path, "rb").read()).hexdigest()))
    finish_run(cur, run, read=len(rows), written=len(rows)); conn.commit()
    print("archived", len(rows), "rows in", len(by_month), "files")
