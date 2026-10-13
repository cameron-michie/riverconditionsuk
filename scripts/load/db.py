"""DB helpers for loaders: one connection, COPY-based bulk insert, source lookup, run bookkeeping."""
import io, json, os, psycopg
DSN = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "raw")

def connect():
    return psycopg.connect(DSN, autocommit=False)

def source_id(cur, slug):
    cur.execute("select id from ref.source where slug=%s", (slug,))
    r = cur.fetchone()
    if not r: raise KeyError(slug)
    return r[0]

# One run log (ops.etl_run). Under the scheduler a job already has a row (ETL_RUN_ID): the script adds its source and row count to it and the
# scheduler records the outcome. Run by hand, the script makes and closes its own row, named after the adapter.
SCHEDULED_RUN = os.environ.get("ETL_RUN_ID")

def start_run(cur, slug, adapter, params=None):
    if SCHEDULED_RUN:
        cur.execute("update ops.etl_run set source_id = coalesce(source_id, %s) where id = %s returning id", (source_id(cur, slug), int(SCHEDULED_RUN)))
        r = cur.fetchone()
        if r: return r[0]
    cur.execute("insert into ops.etl_run (job, source_id, output) values (%s, %s, %s) returning id", (adapter, source_id(cur, slug), json.dumps(params) if params else None))
    return cur.fetchone()[0]

def finish_run(cur, run_id, read=None, written=None, rejected=None, status="ok", error=None):
    if SCHEDULED_RUN and int(SCHEDULED_RUN) == run_id:
        cur.execute("update ops.etl_run set rows_written = coalesce(rows_written, 0) + coalesce(%s, 0), error = coalesce(%s, error) where id = %s", (written, error, run_id))
    else:
        cur.execute("update ops.etl_run set finished_at = now(), status = %s, rows_written = %s, error = %s where id = %s", (status, written, error, run_id))

# geo.gauge_model.normal as rows (site_id, doy, quantiles[21]): the long form the flow scripts work with
NORMALS_SQL = """select m.site_id, 1 + 10 * (k - 1), array(select unnest(m.normal[k:k][1:21])) from geo.gauge_model m, generate_series(1, 37) k
                 where m.normal is not null and m.normal[k][1] is not null"""
# per-gauge catchment area (km2), from the NRFA descriptors on the site
AREA_SQL = "select id, (attrs->>'catchment_area')::float8 from geo.site where (attrs->>'catchment_area')::float8 > 0"

def copy_rows(cur, table, cols, rows):
    """COPY an iterable of tuples. None -> NULL. Returns row count."""
    n = 0
    with cur.copy(f"copy {table} ({','.join(cols)}) from stdin") as cp:
        for r in rows:
            cp.write_row(r); n += 1
    return n

def jdump(x):
    return json.dumps(x, default=str, ensure_ascii=False)
