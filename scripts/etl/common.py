"""Shared bits for the incremental ETL adapters."""
import os, sys
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
from db import copy_rows

def upsert_obs(cur, rows, update=True):
    """rows: (series_id, observed_at, value, quality, completeness). Inserts new readings; with update=True, rewrites readings whose value or quality changed
    (daily QC moves Unchecked -> Good). Moves observation_latest forward. Returns (rows seen, rows written)."""
    if not rows: return 0, 0
    cur.execute("create temp table if not exists stg_u (series_id bigint, observed_at timestamptz, value double precision, quality text, completeness real) on commit drop")
    cur.execute("truncate stg_u")
    copy_rows(cur, "stg_u", ["series_id", "observed_at", "value", "quality", "completeness"], rows)
    action = ("do update set value = excluded.value, quality = excluded.quality, completeness = excluded.completeness "
              "where (core.observation.value, core.observation.quality) is distinct from (excluded.value, excluded.quality)") if update else "do nothing"
    cur.execute(f"""insert into core.observation (series_id, observed_at, value, quality, completeness)
                   select distinct on (series_id, observed_at) series_id, observed_at, value, quality, completeness from stg_u order by series_id, observed_at
                   on conflict (series_id, observed_at) {action}""")
    written = cur.rowcount
    cur.execute("""insert into core.observation_latest (series_id, observed_at, value, quality)
                   select distinct on (series_id) series_id, observed_at, value, quality from stg_u where value is not null order by series_id, observed_at desc
                   on conflict (series_id) do update set observed_at = excluded.observed_at, value = excluded.value, quality = excluded.quality, updated_at = now()
                   where excluded.observed_at >= core.observation_latest.observed_at""")
    cur.execute("""update core.series s set last_at = greatest(coalesce(s.last_at, x.b), x.b), first_at = least(coalesce(s.first_at, x.a), x.a)
                   from (select series_id, min(observed_at) a, max(observed_at) b from stg_u group by 1) x where x.series_id = s.id""")
    return len(rows), written
