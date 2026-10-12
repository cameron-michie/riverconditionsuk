"""DB helpers for loaders: one connection, COPY-based bulk insert, source lookup, run bookkeeping."""
import io, json, os, psycopg
DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "raw")

def connect():
    return psycopg.connect(DSN, autocommit=False)

def source_id(cur, slug):
    cur.execute("select id from ingest.source where slug=%s", (slug,))
    r = cur.fetchone()
    if not r: raise KeyError(slug)
    return r[0]

def start_run(cur, slug, adapter, params=None):
    cur.execute("insert into ingest.run (source_id, adapter, params) values (%s,%s,%s) returning id", (source_id(cur, slug), adapter, json.dumps(params or {})))
    return cur.fetchone()[0]

def finish_run(cur, run_id, read=None, written=None, rejected=None, status="ok", error=None):
    cur.execute("update ingest.run set finished_at=now(), status=%s, rows_read=%s, rows_written=%s, rows_rejected=%s, error=%s where id=%s", (status, read, written, rejected, error, run_id))

def copy_rows(cur, table, cols, rows):
    """COPY an iterable of tuples. None -> NULL. Returns row count."""
    n = 0
    with cur.copy(f"copy {table} ({','.join(cols)}) from stdin") as cp:
        for r in rows:
            cp.write_row(r); n += 1
    return n

def jdump(x):
    return json.dumps(x, default=str, ensure_ascii=False)
