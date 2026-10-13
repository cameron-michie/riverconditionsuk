"""Seasonal flow normals (geo.gauge_model.normal) rebuilt from the cold archive plus whatever daily flow is still in Postgres. Runs quarterly in the `normals` job,
after nrfa_recent.py has added NRFA's newest daily flows to the archive: the one scheduled reader of the archive.
Quantiles 0,5,..,100 % of daily mean flow within +-15 days of each 10th day of the year, NRFA preferred over EA Hydrology for the same day, gauges with at least 3 years.
Usage: flow_normal_refresh.py [--check]   (--check compares with the current normals and writes nothing)"""
import glob, os, sys
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
import numpy as np, pandas as pd, pyarrow.dataset as ds
from db import connect, NORMALS_SQL

import store
ARCH = os.path.join(store.ARCH_DIR, "observation", "daily")
CHECK = "--check" in sys.argv
with connect() as conn, conn.cursor() as cur:
    cur.execute("""select se.id, se.site_id, src.slug = 'nrfa' from live.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'river_flow'
                   join ref.source src on src.id = se.source_id and src.slug in ('nrfa', 'ea_hydrology') where se.aggregation = 'mean' and se.interval_s = 86400""")
    S = pd.DataFrame(cur.fetchall(), columns=["series_id", "site_id", "nrfa"])
    store.fetch_archive(cur, "observation:daily"); parts = []
    if glob.glob(os.path.join(ARCH, "**", "*.parquet"), recursive=True):
        t = ds.dataset(ARCH, format="parquet", partitioning="hive").to_table(columns=["series_id", "observed_at", "value"], filter=ds.field("series_id").isin(S.series_id.tolist()))
        parts.append(t.to_pandas())
    with cur.copy("copy (select o.series_id, o.observed_at, o.value from live.observation o where o.series_id = any(%s) and o.value >= 0) to stdout", (S.series_id.tolist(),)) as cp:
        import io; buf = io.StringIO()
        for chunk in cp: buf.write(bytes(chunk).decode())
    buf.seek(0); parts.append(pd.read_csv(buf, sep="\t", names=["series_id", "observed_at", "value"], na_values="\\N", parse_dates=["observed_at"]))
    d = pd.concat(parts, ignore_index=True); d = d[d.value >= 0].merge(S, on="series_id")
    d["observed_at"] = pd.to_datetime(d["observed_at"], utc=True); d["day"] = d["observed_at"].dt.date
    d = d.sort_values(["site_id", "day", "nrfa", "series_id"], ascending=[True, True, False, True]).drop_duplicates(["site_id", "day"])    # NRFA first; ties broken by series id
    d["doy"] = pd.to_datetime(d["day"]).dt.dayofyear; d["yr"] = pd.to_datetime(d["day"]).dt.year
    print(len(d), "daily flows,", d.site_id.nunique(), "gauges", flush=True)
    steps = np.arange(1, 367, 10); qs = np.linspace(0, 1, 21); out = []
    for sid, g in d.groupby("site_id"):
        doy = g.doy.values; v = g.value.values; yr = g.yr.values
        for st in steps:
            m = np.minimum(np.abs(doy - st), 366 - np.abs(doy - st)) <= 15
            if m.sum() and len(np.unique(yr[m])) >= 3: out.append((int(sid), int(st), np.quantile(v[m], qs).tolist(), int(m.sum()), int(len(np.unique(yr[m])))))
    print(len(out), "normals computed")
    if CHECK:
        cur.execute(NORMALS_SQL); cur_t = {(s, int(dd)): q for s, dd, q in cur.fetchall()}
        new = {(a, b): q for a, b, q, n, y in out}
        both = set(cur_t) & set(new); diff = [k for k in both if not np.allclose(cur_t[k], new[k], rtol=1e-6, atol=1e-9)]
        print(f"current {len(cur_t)}, rebuilt {len(new)}, common {len(both)}, differing {len(diff)}, only current {len(set(cur_t) - set(new))}, only rebuilt {len(set(new) - set(cur_t))}")
        sys.exit(0)
    grid = {}
    for sid, st, q, n, y in out:
        g = grid.setdefault(sid, {"rows": [[None] * 21 for _ in range(37)], "years": 0}); g["rows"][(st - 1) // 10] = q; g["years"] = max(g["years"], y)
    cur.execute("update geo.gauge_model set normal = null, normal_years = null")
    cur.executemany("""insert into geo.gauge_model (site_id, normal, normal_years, built_at) select %s, %s, %s, now() where exists (select 1 from geo.site where id = %s)
                       on conflict (site_id) do update set normal = excluded.normal, normal_years = excluded.normal_years, built_at = now()""",
                    [(sid, g["rows"], g["years"], sid) for sid, g in grid.items()])
    conn.commit()
    print("geo.gauge_model normals rebuilt:", len(grid), "gauges,", len(out), "ten-day steps")
