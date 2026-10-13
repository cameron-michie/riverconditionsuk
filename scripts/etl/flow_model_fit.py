"""Fit a rain-driven flow model per gauge and report skill on a held-out year.
State is the normal score z of the gauge's seasonal flow percentile (same scale as geo.gauge_model.normal / live.seasonal_pct).
  z[d] = c + phi*z[d-1] + b0*r[d] + b1*r[d-1] + b2*r[d-2] + b3*mean(r[d-3..d-7]),   r = sqrt(catchment rain mm), day = 09:00-09:00 UTC (EA convention)
Training 2015-01 .. 2024-09, held out 2024-10 .. 2025-09 (the end of the NRFA daily flow record held locally). Rain: NRFA CEH-GEAR catchment daily rainfall.
Usage: flow_model_fit.py [--save]   (--save writes the model columns of geo.gauge_model)"""
import json, os, sys, time
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
import numpy as np, pandas as pd
from scipy.stats import norm
import lib
from db import connect, NORMALS_SQL, AREA_SQL

RAW = lib.ROOT; T0, TRAIN_END, END = "2015-01-01", "2024-09-30", "2025-09-30"
LAGS = ("r0", "r1", "r2", "r37")
t_start = time.time()
SAVE = "--save" in sys.argv          # production fit: train on every day up to END, write geo.gauge_model, skip the held-out evaluation
if SAVE: TRAIN_END = END

def load_series(path, lo=T0, hi=END):
    d = json.load(open(path))["data-stream"]
    s = pd.Series(d[1::2], index=pd.to_datetime(d[0::2]), dtype="float64")
    return s[(s.index >= lo) & (s.index <= hi)]

def to_z(flow, qtab):
    """flow Series -> normal score via the gauge's seasonal quantiles (21 points per 10-day step)."""
    doy = flow.index.dayofyear.values; step = np.minimum(1 + 10 * np.round((doy - 1) / 10).astype(int), 361)
    z = np.full(len(flow), np.nan); p = np.linspace(0, 100, 21); v = flow.values
    for st in np.unique(step):
        q = qtab.get(int(st))
        if q is None: continue
        m = step == st; qq = np.maximum.accumulate(np.array(q))
        pct = np.interp(v[m], qq, p)
        pct[v[m] <= qq[0]] = 0.0; pct[v[m] >= qq[-1]] = 100.0
        z[m] = norm.ppf(np.clip(pct / 100, 0.005, 0.995))
    return pd.Series(z, index=flow.index)

def design(z, r):
    """feature matrix aligned to z.index, rows needing z[d-1] and rain lags."""
    df = pd.DataFrame({"z": z, "r": r})
    X = pd.DataFrame({"c": 1.0, "zl": df.z.shift(1), "r0": df.r, "r1": df.r.shift(1), "r2": df.r.shift(2), "r37": df.r.shift(3).rolling(5).mean()}, index=df.index)
    return X, df.z

def step(par, zprev, rhist):
    """one day. rhist = dict r0, r1, r2, r37 for the day being predicted."""
    return par[0] + par[1] * zprev + par[2] * rhist[0] + par[3] * rhist[1] + par[4] * rhist[2] + par[5] * rhist[3]

def recursive(par, z0, r, d0, k):
    """predict z for days d0+1..d0+k from z[d0] using the actual rain r (Series, daily index) -> array length k."""
    out, zp = [], z0
    ix = r.index.get_loc(d0)
    for j in range(1, k + 1):
        i = ix + j
        rh = (r.iloc[i], r.iloc[i - 1], r.iloc[i - 2], r.iloc[i - 7:i - 2].mean())
        zp = step(par, zp, rh); out.append(zp)
    return np.array(out)

if __name__ == "__main__":
    with connect() as conn, conn.cursor() as cur:
        cur.execute("select s.value, s.site_id from geo.site_key s where scheme = 'nrfa:id'"); SITE = {v: i for v, i in cur.fetchall()}
        cur.execute(NORMALS_SQL); QT = {}
        for sid, doy, q in cur.fetchall(): QT.setdefault(sid, {})[int(doy)] = q
    ids = [f[:-5] for f in sorted(os.listdir(os.path.join(RAW, "nrfa", "cdr"))) if f[:-5] in SITE and SITE[f[:-5]] in QT]
    print(len(ids), "gauges with rain, flow and normals", flush=True)
    res, params = [], {}
    KS = (1, 2, 3, 5)
    for n, i in enumerate(ids):
        sid = SITE[i]
        try:
            flow = load_series(os.path.join(RAW, "nrfa", "gdf", f"{i}.json")); rain = load_series(os.path.join(RAW, "nrfa", "cdr", f"{i}.json"))
        except Exception: continue
        flow = flow[flow >= 0]
        if len(flow) < 1500: continue
        idx = pd.date_range(T0, END); z = to_z(flow, QT[sid]).reindex(idx); r = np.sqrt(rain.clip(lower=0)).reindex(idx)
        X, y = design(z, r); ok = X.notna().all(axis=1) & y.notna()
        tr = ok & (X.index <= TRAIN_END)
        if tr.sum() < 1000 or (not SAVE and (ok & (X.index > TRAIN_END)).sum() < 200): continue
        beta, *_ = np.linalg.lstsq(X[tr].values, y[tr].values, rcond=None)
        # AR-only baseline (no rain)
        Xa = X[["c", "zl"]]; ba, *_ = np.linalg.lstsq(Xa[tr].values, y[tr].values, rcond=None)
        resid = y[tr].values - X[tr].values @ beta; sd = float(resid.std())
        params[sid] = dict(beta=beta.tolist(), sd=sd, n=int(tr.sum()), r2=float(1 - resid.var() / y[tr].var()))
        if SAVE: continue
        # held-out evaluation: start days in holdout where z[d0] known and rain known for next 5 days
        hold = [d for d in idx[(idx > TRAIN_END) & (idx <= pd.Timestamp(END) - pd.Timedelta(days=5))] if not np.isnan(z.loc[d])]
        e = {k: {"rain": [], "ar": [], "persist": []} for k in KS}
        for d0 in hold[::3]:
            fut = z.loc[d0 + pd.Timedelta(days=1): d0 + pd.Timedelta(days=5)]
            if fut.isna().any() or r.loc[d0 - pd.Timedelta(days=8): d0 + pd.Timedelta(days=5)].isna().any(): continue
            zr = recursive(beta, z.loc[d0], r, d0, 5)
            za = [ba[0] + ba[1] * z.loc[d0]]; 
            for _ in range(4): za.append(ba[0] + ba[1] * za[-1])
            for k in KS:
                e[k]["rain"].append(abs(zr[k - 1] - fut.iloc[k - 1])); e[k]["ar"].append(abs(za[k - 1] - fut.iloc[k - 1])); e[k]["persist"].append(abs(z.loc[d0] - fut.iloc[k - 1]))
        if len(e[1]["rain"]) < 30: continue
        res.append({"site": sid, "nrfa": i, **{f"{m}{k}": float(np.mean(e[k][m])) for k in KS for m in ("rain", "ar", "persist")}})
        if n % 200 == 0: print(n, len(res), round(time.time() - t_start), "s", flush=True)
    if SAVE:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("update geo.gauge_model set beta = null, sd = null, r2 = null, trained_through = null")
            cur.executemany("""insert into geo.gauge_model (site_id, beta, sd, r2, trained_through) select %s, %s, %s, %s, %s where exists (select 1 from geo.site where id = %s)
                               on conflict (site_id) do update set beta = excluded.beta, sd = excluded.sd, r2 = excluded.r2, trained_through = excluded.trained_through, built_at = now()""",
                            [(sid, p["beta"], p["sd"], p["r2"], END, sid) for sid, p in params.items()])
            conn.commit()
        print("saved parameters for", len(params), "gauges"); sys.exit(0)
    R = pd.DataFrame(res); print(len(R), "gauges evaluated")
    print("median MAE in normal-score units (lower is better), held-out year")
    print(pd.DataFrame({k: {m: R[f"{m}{k}"].median() for m in ("persist", "ar", "rain")} for k in KS}).round(3))
    print("share of gauges where the rain model beats persistence:", {k: round(float((R[f'rain{k}'] < R[f'persist{k}']).mean()), 2) for k in KS})
    print("median coefficients:", np.median([p["beta"] for p in params.values()], axis=0).round(3), "median r2", round(float(np.median([p["r2"] for p in params.values()])), 3))
    R.to_csv(os.path.join(lib.ROOT, "..", "flow_model_eval.csv"), index=False)
    json.dump({str(k): v for k, v in params.items()}, open(os.path.join(lib.ROOT, "..", "flow_model_params.json"), "w"))
