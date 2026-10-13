"""Leave-one-gauge-out test of the regionalised model: the target gauge is treated as ungauged. Its starting state and parameters come from the nearest donors
(inverse-distance and river-size weighting, as in live.refresh_flow_signals); its own catchment rain drives the forecast. Compared with holding the donors' state constant."""
import json, os, sys, time
sys.path[:0] = [os.path.dirname(os.path.abspath(__file__))]
import numpy as np, pandas as pd
from flow_model_fit import *
from scipy.spatial import cKDTree

RADII = [60, 100, 150]
with connect() as conn, conn.cursor() as cur:
    cur.execute("select s.value, s.site_id, ST_X(si.geom), ST_Y(si.geom), coalesce(l.size_class, 0) from geo.site_key s join geo.site si on si.id = s.site_id left join geo.river_link l on l.id = si.river_link_id where s.scheme = 'nrfa:id'")
    INFO = {v: (sid, x, y, sz) for v, sid, x, y, sz in cur.fetchall()}
    cur.execute(NORMALS_SQL); QT = {}
    for sid, doy, q in cur.fetchall(): QT.setdefault(sid, {})[int(doy)] = q
P = {int(k): v for k, v in json.load(open(os.path.join(lib.ROOT, "..", "flow_model_params.json"))).items()}
ids = [i for i, (sid, *_r) in INFO.items() if sid in P and os.path.exists(os.path.join(RAW, "nrfa", "cdr", f"{i}.json"))]
idx = pd.date_range(T0, END); Z, Rr = {}, {}
for i in ids:
    sid = INFO[i][0]; flow = load_series(os.path.join(RAW, "nrfa", "gdf", f"{i}.json")); flow = flow[flow >= 0]
    Z[i] = to_z(flow, QT[sid]).reindex(idx); Rr[i] = np.sqrt(load_series(os.path.join(RAW, "nrfa", "cdr", f"{i}.json")).clip(lower=0)).reindex(idx)
xy = np.array([[INFO[i][1] * 71.5, INFO[i][2] * 111.2] for i in ids]); tree = cKDTree(xy)       # km, good enough at UK latitudes
sz = np.array([INFO[i][3] for i in ids]); beta = np.array([P[INFO[i][0]]["beta"] for i in ids]); ZZ = np.stack([Z[i].values for i in ids])
hold = idx[(idx > TRAIN_END) & (idx <= pd.Timestamp(END) - pd.Timedelta(days=5))][::7]
SPIN = (0, 1, 2, 4, 7); KS = (0, 1, 2, 3, 5); out = {n: {k: [] for k in KS} for n in SPIN}; R = 100
for t, i in enumerate(ids):
    zt = Z[i]; rt = Rr[i]
    dist, nb = tree.query(xy[t], k=9, distance_upper_bound=R); keep = [(d, j) for d, j in zip(dist, nb) if j < len(ids) and j != t][:6]
    if len(keep) < 2 and not (keep and keep[0][0] < 20): continue
    d = np.array([a for a, _ in keep]); js = np.array([j for _, j in keep]); w = 1 / (d + 10) ** 2 * np.exp(-0.6 * np.abs(sz[js] - sz[t])); w /= w.sum()
    par = (w[:, None] * beta[js]).sum(0)
    for d0 in hold:
        fut = zt.loc[d0: d0 + pd.Timedelta(days=5)]
        if fut.isna().any() or rt.loc[d0 - pd.Timedelta(days=16): d0 + pd.Timedelta(days=5)].isna().any(): continue
        for n in SPIN:
            ds = d0 - pd.Timedelta(days=n); zd = ZZ[js, idx.get_loc(ds)]
            if np.isnan(zd).any(): break
            zs = float((w * zd).sum())
            path = np.concatenate([[zs], recursive(par, zs, rt, ds, n + 5)]) if n else np.concatenate([[zs], recursive(par, zs, rt, d0, 5)])
            for k in KS: out[n][k].append(abs(path[n + k] - fut.iloc[k]))
print("MAE of normal score, ungauged (leave-one-out), by spin-up days n (0 = donors' state now) and lead k days")
print(pd.DataFrame({n: {k: np.mean(out[n][k]) for k in KS} for n in SPIN}).round(3).T)
