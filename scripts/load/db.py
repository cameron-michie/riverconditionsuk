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

def term_native(cur, domain):
    """upstream spelling (lower case) -> code, for a ref.term vocabulary"""
    cur.execute("select lower(n), code from ref.term, unnest(native) n where domain = %s", (domain,))
    return dict(cur.fetchall())

def wfd_status_map(cur):
    """upstream WFD status spelling (lower case) -> (canonical status, rank)"""
    cur.execute("select lower(n), code, sort from ref.term, unnest(native) n where domain = 'wfd_status'")
    return {n: (c, r) for n, c, r in cur.fetchall()}

def fold_classes(cur, stg):
    """Merge staged WFD classifications (temp table with waterbody_id, cycle, year, element, status, certainty) into geo.waterbody.classes.
    Per element it keeps the latest rated assessment (an unrated one only where nothing is rated) with its rank, and the previous cycle's status and rank,
    which is what the dossiers show and compute_signals.sql scores."""
    cur.execute(f"""
      create temp table _fc on commit drop as
      with staged as (select distinct on (waterbody_id, element, cycle) waterbody_id, element, cycle, year, status, certainty from {stg}
                      order by waterbody_id, element, cycle, year desc),
      held as (select w.id waterbody_id, c.key element, (c.value->>'cycle')::int as cycle, (c.value->>'year')::int as year, c.value->>'status' status, c.value->>'certainty' certainty
               from geo.waterbody w cross join lateral jsonb_each(w.classes) c where w.id in (select waterbody_id from {stg})
               union all
               select w.id, c.key, null, null, c.value->>'prev', null from geo.waterbody w cross join lateral jsonb_each(w.classes) c
               where w.id in (select waterbody_id from {stg}) and c.value ? 'prev')
      select a.*, t.sort status_rank from (
        select * from staged union all
        select h.* from held h where not exists (select 1 from staged s where s.waterbody_id = h.waterbody_id and s.element = h.element and s.cycle is not distinct from h.cycle)) a
      left join ref.term t on t.domain = 'wfd_status' and t.code = a.status""")
    cur.execute("create index on _fc (waterbody_id, element)")
    cur.execute("""
      with ranked as (select *, row_number() over (partition by waterbody_id, element order by (status_rank is not null) desc, cycle desc nulls last, year desc nulls last) rn from _fc)
      update geo.waterbody w set classes = w.classes || x.c
      from (select c.waterbody_id, jsonb_object_agg(c.element, jsonb_strip_nulls(jsonb_build_object('status', c.status, 'rank', c.status_rank, 'year', c.year, 'cycle', c.cycle,
                     'certainty', c.certainty, 'prev', p.status, 'prev_rank', p.status_rank))) c
            from ranked c left join lateral (select status, status_rank from _fc p where p.waterbody_id = c.waterbody_id and p.element = c.element
                                             and (p.cycle < c.cycle or (p.cycle is null and c.cycle is not null))
                                             order by (p.status_rank is not null) desc, p.cycle desc nulls last, p.year desc nulls last limit 1) p on true
            where c.rn = 1 group by c.waterbody_id) x
      where x.waterbody_id = w.id""")
    n = cur.rowcount
    cur.execute("drop table _fc")
    return n

def copy_rows(cur, table, cols, rows):
    """COPY an iterable of tuples. None -> NULL. Returns row count."""
    n = 0
    with cur.copy(f"copy {table} ({','.join(cols)}) from stdin") as cp:
        for r in rows:
            cp.write_row(r); n += 1
    return n

def jdump(x):
    return json.dumps(x, default=str, ensure_ascii=False)
