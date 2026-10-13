"""Rain-driven flow forecast, now and the next 5 days, for every river waterbody and every gauge. Runs hourly after the live refresh.

Per waterbody: starting state = the flow signal that core.refresh_flow_signals() already derives (measured gauge, or a weighted mix of nearby gauges); parameters =
the same gauges' fitted models (core.flow_model_param); driver = area-weighted rain over the waterbody and everything upstream of it (radar to now, ECMWF after).
Validated leave-one-gauge-out on a held-out year (scripts/etl/flow_model_transfer_eval.py): 5-day error 0.47 vs 0.73 normal-score units for holding the
neighbours' state constant; see docs/FLOW_MODEL.md. Output: core.waterbody_flow (modelled), core.forecast (gauge flow, m3/s with a p10-p90 band)."""
import datetime as dt, json, os, sys
sys.path[:0] = [os.path.dirname(os.path.abspath(__file__))]
import numpy as np
from scipy.stats import norm
import common, wb_graph
from db import connect, copy_rows, start_run, finish_run
from flow_model_fit import step

UTC = dt.timezone.utc
DAY_H = 9                                  # model day = 09:00 -> 09:00 UTC, the EA convention the model was trained on
BACK, FWD = 8, 5
now = dt.datetime.now(UTC).replace(second=0, microsecond=0)
issued = now.replace(minute=0)
D0 = (now - dt.timedelta(hours=DAY_H)).date()
days = [D0 + dt.timedelta(days=k) for k in range(-BACK, FWD + 1)]; N = len(days); I0 = BACK
day_of = lambda t: ((t - dt.timedelta(hours=DAY_H, minutes=1)).date() - days[0]).days
CLIM_R = 1.0                               # sqrt(mm), used only where radar history is missing

def pct_to_z(p): return norm.ppf(np.clip(np.asarray(p, dtype=float) / 100, 0.005, 0.995))

with connect() as conn, conn.cursor() as cur:
    run = start_run(cur, "ecmwf_ifs", "flow_forecast", {"issued": issued.isoformat()})
    cur.execute("select ops.roll_forecast_partitions()")
    g = wb_graph.build(cur); W = g["wids"]; ix = {w: i for i, w in enumerate(W)}
    # ── rain: radar (past) then IFS (future), per waterbody, per model day, local catchment mm
    cur.execute("select max(valid_at) from wx.catchment_rain where source = 'radar'"); t_radar = cur.fetchone()[0]
    cur.execute("select max(issued_at) from wx.catchment_rain where source = 'ifs'"); ifs_run = cur.fetchone()[0]
    if t_radar is None or ifs_run is None: print("no rain data yet"); finish_run(cur, run, status="skipped", error="no rain"); conn.commit(); sys.exit(0)
    rain = np.zeros((len(W), N)); cover = np.zeros(N)         # cover: hours of the day with data
    cur.execute("select waterbody_id, valid_at, mm from wx.catchment_rain where source = 'radar' and valid_at > %s", (days[0],))
    for w, t, mm in cur.fetchall():
        i = ix.get(w); d = day_of(t)
        if i is not None and 0 <= d < N: rain[i, d] += mm
    cur.execute("select distinct valid_at from wx.catchment_rain where source = 'radar' and valid_at > %s", (days[0],))
    for (t,) in cur.fetchall():
        d = day_of(t)
        if 0 <= d < N: cover[d] += 0.25
    cur.execute("select waterbody_id, valid_at, mm, step_min from wx.catchment_rain where source = 'ifs' and issued_at = %s and valid_at > %s", (ifs_run, t_radar))
    for w, t, mm, st in cur.fetchall():
        i = ix.get(w); d = day_of(t); frac = min(1.0, (t - t_radar).total_seconds() / (st * 60))
        if i is not None and 0 <= d < N: rain[i, d] += mm * frac
    cur.execute("select distinct valid_at, step_min from wx.catchment_rain where source = 'ifs' and issued_at = %s and valid_at > %s", (ifs_run, t_radar))
    for t, st in cur.fetchall():
        d = day_of(t)
        if 0 <= d < N: cover[d] += st / 60 * min(1.0, (t - t_radar).total_seconds() / (st * 60))
    # ── upstream-area-weighted rain, no lag (the training rain is a plain catchment average)
    area = np.array([g["area"][w] for w in W]); S = rain * area[:, None]
    for w in g["order"]:
        t = g["down"].get(w)
        if t is not None: S[ix[t]] += S[ix[w]]
    up = np.array([g["up_area"][w] for w in W]); reff = np.sqrt(np.clip(S / up[:, None], 0, None))
    for k in range(N):                                         # a day without enough rain data: typical rain in the past, unknown (stops the forecast) in the future
        if cover[k] < 21: reff[:, k] = CLIM_R if k <= I0 else np.nan
    last_k = max([k for k in range(I0, N) if cover[k] >= 21] or [I0])         # last future day with (nearly) full coverage
    print(f"rain: radar to {t_radar:%d %b %H:%M}, IFS run {ifs_run:%d %b %Hz}; forecast days with full cover: {last_k - I0}", flush=True)
    # ── starting states and parameters
    cur.execute("select site_id, beta, sd from core.flow_model_param"); PAR = {s: (np.array(b), sd) for s, b, sd in cur.fetchall()}
    med_beta = np.median([p[0] for p in PAR.values()], axis=0); med_sd = float(np.median([p[1] for p in PAR.values()]))
    cur.execute("select site_id, doy, q from core.flow_normal"); QN = {}
    for sid, doy, q in cur.fetchall(): QN.setdefault(sid, {})[int(doy)] = np.maximum.accumulate(np.array(q))
    cur.execute("select site_id, value_num from core.site_attribute where key = 'catchment_area' and value_num > 1"); AREA = dict(cur.fetchall())
    PGRID = np.linspace(0, 100, 21)
    def flow_m3s(donors, wts, pct, day, target_area):
        """specific discharge of the donors at this percentile and time of year (geometric mean, weights as for the state), scaled by the target's catchment area.
        Tested leave-one-gauge-out: median error x1.8, 57% within a factor of 2 (docs/FLOW_MODEL.md)."""
        st = min(1 + 10 * int(round((day.timetuple().tm_yday - 1) / 10)), 361); acc = tw = 0.0
        for (g, _, _), wt in zip(donors, wts):
            q = QN.get(g, {}).get(st); a = AREA.get(g)
            if q is None or a is None: continue
            acc += wt * np.log(max(float(np.interp(pct, PGRID, q)), 1e-6) / a); tw += wt
        return float(target_area * np.exp(acc / tw)) if tw > 0 and target_area else None
    cur.execute("select entity_id, basis from core.signal where signal_code = 'flow' and entity_kind = 'waterbody'")
    rows_wf, nfc = [], 0
    def forecast(z0, beta, w):
        """z for model days D0+1 .. last_k, from state z0 (day D0), driven by that waterbody's rain."""
        out, zp, i = [], z0, ix[w]
        for k in range(I0 + 1, last_k + 1):
            r = reff[i]
            rh = (r[k], r[k - 1], r[k - 2], np.nanmean(r[k - 7:k - 2]))
            if np.isnan(rh).any(): break
            zp = step(beta, zp, rh); out.append(zp)
        return out
    for wid, basis in cur.fetchall():
        if wid not in ix: continue
        b = basis if isinstance(basis, dict) else json.loads(basis)
        if b.get("method") == "measured":
            donors = [(b["gauge"], 1.0, b["pct"])]
        else:
            donors = [(d["gauge"], 1 / (d["km"] + 10) ** 2, d["pct"]) for d in b.get("donors", []) if d.get("pct") is not None]
        if not donors: continue
        wts = np.array([d[1] for d in donors]); wts /= wts.sum(); z0 = float((wts * pct_to_z([d[2] for d in donors])).sum())
        have = [(wt, PAR[d[0]]) for wt, d in zip(wts, donors) if d[0] in PAR]
        if have:
            sw = sum(h[0] for h in have); beta = sum(h[0] * h[1][0] for h in have) / sw; sd = sum(h[0] * h[1][1] for h in have) / sw
        else: beta, sd = med_beta, med_sd
        method = "measured" if b.get("method") == "measured" and b.get("on_stretch") else "transfer"
        A_t = AREA.get(donors[0][0]) if method == "measured" else g["up_area"].get(wid)       # a gauge on the stretch: its own area; otherwise the drainage graph's upstream area
        rows_wf.append((wid, issued, now.replace(minute=0), float(100 * norm.cdf(z0)), method, b.get("confidence"), json.dumps({"sd_z": round(sd, 3), "state": b.get("method"), "donors": [d[0] for d in donors], "area_km2": round(A_t, 1) if A_t else None, "q_factor": 1.3 if method == "measured" else 2.0}),
                        flow_m3s(donors, wts, 100 * norm.cdf(z0), now.date(), A_t)))
        for j, z in enumerate(forecast(z0, beta, wid), 1):
            valid = dt.datetime.combine(days[I0 + j], dt.time(DAY_H + 12), UTC)
            rows_wf.append((wid, issued, valid, float(100 * norm.cdf(z)), "rain_routed", "low" if j > 3 or b.get("confidence") == "low" else b.get("confidence") or "medium",
                            json.dumps({"sd_z": round(sd * np.sqrt(j), 3), "lead_days": j, "donors": [d[0] for d in donors], "area_km2": round(A_t, 1) if A_t else None, "q_factor": 1.3 if method == "measured" else 2.0}),
                            flow_m3s(donors, wts, 100 * norm.cdf(z), days[I0 + j], A_t)))
    cur.execute("create temp table stg_wf (w bigint, i timestamptz, v timestamptz, pct real, m text, c text, basis jsonb, q double precision) on commit drop")
    copy_rows(cur, "stg_wf", ["w", "i", "v", "pct", "m", "c", "basis", "q"], rows_wf)
    cur.execute("""insert into core.waterbody_flow (waterbody_id, issued_at, valid_at, flow_pct, flow_m3s, method, confidence, basis) select w, i, v, pct, q, m, c, basis from stg_wf
                   on conflict (waterbody_id, issued_at, valid_at) do update set flow_pct = excluded.flow_pct, flow_m3s = excluded.flow_m3s, method = excluded.method, confidence = excluded.confidence, basis = excluded.basis""")
    cur.execute("delete from core.waterbody_flow where issued_at < %s", (issued - dt.timedelta(hours=3),))
    # ── gauges: flow in m3/s with a band, via the seasonal quantiles
    cur.execute("""select distinct on (se.site_id) se.site_id, se.id, s.waterbody_id from core.series se join ref.parameter p on p.id = se.parameter_id and p.code = 'river_flow'
                   join core.observation_latest l on l.series_id = se.id join core.site s on s.id = se.site_id
                   where l.observed_at > now() - interval '3 days' and l.value is not null order by se.site_id, (se.interval_s = 900) desc, l.observed_at desc""")
    gauges = cur.fetchall(); cur.execute("select site_id, flow_pct from core.gauge_state where flow_pct is not null"); GP = dict(cur.fetchall())
    pgrid = PGRID; rows_f = []
    for sid, ser, wid in gauges:
        if sid not in PAR or wid not in ix or sid not in GP: continue
        beta, sd = PAR[sid]; z0 = float(pct_to_z(GP[sid]))
        for j, z in enumerate(forecast(z0, beta, wid), 1):
            day = days[I0 + j]; step_ = min(1 + 10 * int(round((day.timetuple().tm_yday - 1) / 10)), 361); q = QN[sid].get(step_)
            if q is None: continue
            f = lambda zz: float(np.interp(100 * norm.cdf(zz), pgrid, q))
            rows_f.append((ser, issued, dt.datetime.combine(day, dt.time(DAY_H + 12), UTC), f(z), f(z - 1.2816 * sd * np.sqrt(j)), f(z + 1.2816 * sd * np.sqrt(j))))
    cur.execute("create temp table stg_f (s bigint, i timestamptz, v timestamptz, val float8, p10 float8, p90 float8) on commit drop")
    copy_rows(cur, "stg_f", ["s", "i", "v", "val", "p10", "p90"], rows_f)
    cur.execute("""insert into core.forecast (series_id, issued_at, valid_at, value, p10, p90) select * from stg_f
                   on conflict (series_id, issued_at, valid_at) do update set value = excluded.value, p10 = excluded.p10, p90 = excluded.p90""")
    cur.execute("delete from core.forecast where issued_at < %s", (issued - dt.timedelta(hours=3),))
    finish_run(cur, run, written=len(rows_wf) + len(rows_f)); conn.commit()
    print(f"flow forecast {issued:%d %b %H:%M}: {len({r[0] for r in rows_wf})} waterbodies, {len(rows_wf)} rows; {len({r[0] for r in rows_f})} gauges, {len(rows_f)} rows")
