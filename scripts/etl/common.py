"""Shared bits for the incremental ETL adapters."""
import os, sys
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
from db import copy_rows

def upsert_obs(cur, rows, update=True):
    """rows: (series_id, observed_at, value, quality[, completeness[, censor[, detection_limit]]]). Inserts new readings into live.observation; with update=True, rewrites
    readings whose value or quality changed (daily QC moves Unchecked -> Good). Moves each series' latest_* forward. Returns (rows seen, rows written).
    completeness and detection_limit are accepted for compatibility and not stored."""
    if not rows: return 0, 0
    rows = [(r[0], r[1], r[2], r[3], r[5] if len(r) > 5 else None) for r in rows]
    cur.execute("create temp table if not exists stg_u (series_id bigint, observed_at timestamptz, value double precision, quality text, censor text) on commit drop")
    cur.execute("truncate stg_u")
    copy_rows(cur, "stg_u", ["series_id", "observed_at", "value", "quality", "censor"], rows)
    return merge_staged(cur, "stg_u", update)

def merge_staged(cur, stg, update=True):
    """Merge a staging table (series_id, observed_at, value, quality, censor) into live.observation and live.series.latest_*. Returns (rows staged, rows written)."""
    action = ("do update set value = excluded.value, quality = excluded.quality, censor = excluded.censor "
              "where (live.observation.value, live.observation.quality) is distinct from (excluded.value, excluded.quality)") if update else "do nothing"
    cur.execute(f"""insert into live.observation (series_id, observed_at, value, quality, censor)
                   select distinct on (series_id, observed_at) series_id, observed_at, value, coalesce(quality, 'unchecked'), censor from {stg} order by series_id, observed_at
                   on conflict (series_id, observed_at) {action}""")
    written = cur.rowcount
    cur.execute(f"""update live.series s set latest_at = x.observed_at, latest_value = x.value, latest_censor = x.censor, latest_quality = x.quality,
                          last_at = greatest(coalesce(s.last_at, x.b), x.b), first_at = least(coalesce(s.first_at, x.a), x.a)
                   from (select distinct on (series_id) series_id, observed_at, value, censor, quality,
                                min(observed_at) over (partition by series_id) a, max(observed_at) over (partition by series_id) b
                         from {stg} where value is not null or censor is not null order by series_id, observed_at desc) x
                   where x.series_id = s.id and (s.latest_at is null or x.observed_at >= s.latest_at)""")
    cur.execute(f"select count(*) from {stg}")
    return cur.fetchone()[0], written
