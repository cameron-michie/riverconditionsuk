"""How well does 'neighbours' specific discharge x my catchment area' predict flow in m3/s at an ungauged point? Leave-one-gauge-out on 2024-10..2025-09.
Estimate: Q = A * exp(sum w ln(q_n(p) / A_n)), q_n(p) = neighbour n's seasonal quantile curve at percentile p. Two ways to get p: the gauge's own true percentile (isolates the
scaling error) or the neighbours' percentiles on the day (the full operational estimate). Two areas: NRFA's published area, or the drainage graph's upstream area."""
import os, sys
sys.path[:0] = [os.path.dirname(os.path.abspath(__file__))]
import numpy as np, pandas as pd
from scipy.spatial import cKDTree
from scipy.stats import norm
from flow_model_fit import *
import wb_graph

with connect() as conn, conn.cursor() as cur:
    cur.execute("select s.value, s.site_id, ST_X(si.geom), ST_Y(si.geom), si.waterbody_id from core.site_identifier s join core.site si on si.id = s.site_id where s.scheme = 'nrfa:id'"); INFO = {v: (sid, x, y, w) for v, sid, x, y, w in cur.fetchall()}
    cur.execute("select site_id, value_num from core.site_attribute where key = 'catchment_area'"); AREA = dict(cur.fetchall())
    cur.execute("select site_id, doy, q from core.flow_normal"); QT = {}
    for sid, doy, q in cur.fetchall(): QT.setdefault(sid, {})[int(doy)] = np.maximum.accumulate(np.array(q))
    G = wb_graph.build(cur)
ids = [i for i, (sid, *_r) in INFO.items() if sid in QT and AREA.get(sid, 0) > 1 and os.path.exists(os.path.join(RAW, "nrfa", "gdf", f"{i}.json"))]
idx = pd.date_range("2024-10-01", "2025-09-30"); FL = {}
for i in ids:
    f = load_series(os.path.join(RAW, "nrfa", "gdf", f"{i}.json"), lo="2024-10-01"); FL[i] = f[f > 0].reindex(idx)
xy = np.array([[INFO[i][1] * 71.5, INFO[i][2] * 111.2] for i in ids]); tree = cKDTree(xy); A = np.array([AREA[INFO[i][0]] for i in ids]); sites = [INFO[i][0] for i in ids]
grid = np.linspace(0, 100, 21); step = lambda d: min(1 + 10 * int(round((d.dayofyear - 1) / 10)), 361)
dates = idx[::15]; res = []
for t, i in enumerate(ids):
    sid, _, _, wb = INFO[i]; Ag_graph = G["up_area"].get(wb); Ag_mid = (G["up_area"][wb] - 0.5 * G["area"][wb]) if wb in G["up_area"] else None
    dist, nb = tree.query(xy[t], k=9, distance_upper_bound=100); keep = [(d, j) for d, j in zip(dist, nb) if j < len(ids) and j != t][:6]
    if len(keep) < 3: continue
    d = np.array([a for a, _ in keep]); js = [j for _, j in keep]
    w = 1 / (d + 10) ** 2 * np.exp(-np.abs(np.log(A[js] / A[t]))); w /= w.sum()
    for day in dates:
        q = FL[i].get(day)
        if q is None or np.isnan(q): continue
        st = step(day); qa = QT[sid].get(st)
        if qa is None: continue
        p_true = float(np.interp(q, qa, grid)); nq = [QT[sites[j]].get(st) for j in js]
        if any(x is None for x in nq): continue
        zn = [FL[ids[j]].get(day) for j in js]
        pn = [float(np.interp(z, n, grid)) if z is not None and not np.isnan(z) else np.nan for z, n in zip(zn, nq)]
        def est(p, area): return area * np.exp(sum(wi * np.log(max(np.interp(p, grid, n), 1e-6) / A[j]) for wi, n, j in zip(w, nq, js)))
        row = {"site": sid, "q": q, "area": A[t]}
        row["A_true__p_true"] = est(p_true, A[t])
        if Ag_graph: row["A_graph__p_true"] = est(p_true, Ag_graph); row["A_mid__p_true"] = est(p_true, Ag_mid)
        if not np.isnan(pn).any():
            pe = 100 * norm.cdf(float(np.sum(w * norm.ppf(np.clip(np.array(pn) / 100, .005, .995)))))
            row["A_true__p_est"] = est(pe, A[t])
            if Ag_graph: row["A_graph__p_est"] = est(pe, Ag_graph); row["A_mid__p_est"] = est(pe, Ag_mid)
        res.append(row)
R = pd.DataFrame(res); print(len(R), "gauge-days from", R.site.nunique(), "gauges")
out = {}
for c in [c for c in R if c.startswith("A_")]:
    r = np.log(R[c] / R.q).dropna(); out[c] = {"n": len(r), "median bias (x)": float(np.exp(r.median())), "median abs error (x)": float(np.exp(r.abs().median())), "within 1.5x": float((r.abs() < np.log(1.5)).mean()), "within 2x": float((r.abs() < np.log(2)).mean())}
pd.set_option("display.width", 200); print(pd.DataFrame(out).T.round(2).to_string())
