"""Series + observations: EA flood (15-min archive), EA hydrology (daily), NRFA (gdf), EA WQ archive (lab chemistry)."""
import sys, os, io, re, glob, json, gzip, time, collections
import pandas as pd, numpy as np
from db import *
t0 = time.time()
which = sys.argv[1:] or ["flood", "hydrology", "nrfa", "wq"]
def L(p): return json.load(open(os.path.join(RAW, p)))

def copy_df(cur, table, df):
    buf = io.StringIO(); df.to_csv(buf, index=False, header=False, na_rep="\\N")
    cols = ",".join(df.columns)
    with cur.copy(f"copy {table} ({cols}) from stdin with (format csv, null '\\N')") as cp:
        buf.seek(0)
        while chunk := buf.read(1 << 22): cp.write(chunk)
    return len(df)

with connect() as conn, conn.cursor() as cur:
    cur.execute("select scheme, value, site_id from core.site_identifier where scheme in ('ea_flood:stationReference','ea_hydro:guid','nrfa:id','ea_wims:notation')")
    SITE = {(s, v): i for s, v, i in cur.fetchall()}
    cur.execute("select id, kind from core.site"); KIND = dict(cur.fetchall())
    cur.execute("select code, id from ref.parameter"); PARAM = dict(cur.fetchall())
    cur.execute("select id, aliases, factor, \"offset\" from ref.unit"); UNIT = {}
    for uid, al, f, o in cur.fetchall():
        UNIT[uid.lower()] = (uid, float(f), float(o))
        for a in al: UNIT[a.lower()] = (uid, float(f), float(o))
    SRC = {s: source_id(cur, s) for s in ("ea_flood_monitoring", "ea_hydrology", "nrfa", "ea_wq_archive")}
    def seq(n):
        cur.execute("select nextval(pg_get_serial_sequence('core.series','id')) from generate_series(1,%s)", (n,)); return [r[0] for r in cur.fetchall()]
    def make_series(rows):
        """rows: dict key -> dict(site, param, src, agg, interval, unit, native_unit, qualifier, datum, ev, matrix, fraction, method)"""
        cur.execute("drop table if exists stg_series"); ids = seq(len(rows)); cur.execute("create temp table stg_series (id bigint, site_id bigint, parameter_id bigint, source_id bigint, key text, agg text, interval_s int, unit text, native_unit text, qualifier text, datum text, ev text, matrix text, fraction text, method text) on commit drop")
        copy_rows(cur, "stg_series", ["id", "site_id", "parameter_id", "source_id", "key", "agg", "interval_s", "unit", "native_unit", "qualifier", "datum", "ev", "matrix", "fraction", "method"],
                  ((i, r["site"], r["param"], r["src"], k, r["agg"], r["interval"], r["unit"], r["native_unit"], r.get("qualifier"), r.get("datum"), r["ev"], r.get("matrix", "river_water"), r.get("fraction"), r.get("method")) for i, (k, r) in zip(ids, rows.items())))
        cur.execute("""insert into core.series (id, site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, qualifier, datum, evidence_class, matrix, fraction, method)
                       overriding system value select id, site_id, parameter_id, source_id, key, agg, interval_s, unit, native_unit, qualifier, datum, ev::text, matrix, fraction, method from stg_series on conflict (source_id, source_series_key) do nothing""")
        cur.execute("select source_series_key, id from core.series where source_id = any(%s)", (list({r["src"] for r in rows.values()}),))
        return dict(cur.fetchall())

    # ═════════ EA flood-monitoring ═════════
    if "flood" in which:
        PMAP = {"level": "water_level", "flow": "river_flow", "rainfall": "rainfall", "temperature": "water_temperature"}
        AGG = {"instantaneous": "instant", "total": "sum", "mean": "mean", "cumulative total": "sum"}
        rows, rej = {}, collections.Counter()
        for m in L("ea_flood/measures.json")["items"]:
            sid = SITE.get(("ea_flood:stationReference", m.get("stationReference")))
            p = PMAP.get(m.get("parameter")); u = UNIT.get((m.get("unitName") or "").lower())
            if not sid: rej["no site"] += 1; continue
            if not p: rej["param:" + str(m.get("parameter"))] += 1; continue
            if not u or m.get("unitName") in ("---", None): rej["unit:" + str(m.get("unitName"))] += 1; continue
            if p == "water_level" and KIND.get(sid) == "groundwater_station": p = "groundwater_level"
            un = m["unitName"]; datum = un if un in ("mASD", "mAOD", "mBDAT") else None
            rows[m["notation"]] = dict(site=sid, param=PARAM[p], src=SRC["ea_flood_monitoring"], agg=AGG.get(m.get("valueType"), "instant"), interval=m.get("period"), unit=u[0], native_unit=un,
                                       qualifier=m.get("qualifier"), datum=datum, ev="official_monitoring")
        print("flood series candidates", len(rows), "rejected", dict(rej))
        smap = make_series(rows)
        fmap = {k: (smap[k], UNIT[rows[k]["native_unit"].lower()][1], UNIT[rows[k]["native_unit"].lower()][2]) for k in rows if k in smap}
        cur.execute("create temp table stg_obs (series_id bigint, observed_at timestamptz, value double precision, quality text) on commit drop")
        tot = 0
        for f in sorted(glob.glob(os.path.join(RAW, "ea_flood", "archive", "*.csv.gz"))):
            d = pd.read_csv(f, dtype=str); d["key"] = d["measure"].str.rsplit("/", n=1).str[-1]
            sm = d["key"].map(lambda k: fmap.get(k)); d = d[sm.notna()].copy(); sm = sm[sm.notna()]
            d["series_id"] = sm.map(lambda t: t[0]).astype("int64")
            pipe = d["value"].str.contains(r"\|", na=False)
            d["v"] = pd.to_numeric(d["value"].str.split("|").str[0], errors="coerce")
            d["v"] = d["v"] * sm.map(lambda t: t[1]).astype(float) + sm.map(lambda t: t[2]).astype(float)
            d["quality"] = np.where(pipe, "suspect", "unchecked")
            d = d[d["v"].notna()]
            out = pd.DataFrame({"series_id": d["series_id"], "observed_at": pd.to_datetime(d["dateTime"], utc=True), "value": d["v"], "quality": d["quality"]})
            tot += copy_df(cur, "stg_obs", out); print(os.path.basename(f), len(out), round(time.time() - t0, 1), "s", flush=True)
        cur.execute("insert into core.observation (series_id, observed_at, value, quality) select series_id, observed_at, value, quality from stg_obs on conflict do nothing")
        cur.execute("truncate stg_obs"); print("flood observations", tot)

    # ═════════ EA hydrology ═════════
    if "hydrology" in which:
        gmap = {}
        for st in L("ea_hydrology/stations.json")["items"]:
            for m in st.get("measures", []): gmap[m["@id"].rsplit("/", 1)[-1]] = (st.get("stationGuid")[0] if isinstance(st.get("stationGuid"), list) else st.get("stationGuid"))
        rows, files = {}, {}
        for f in glob.glob(os.path.join(RAW, "ea_hydrology", "readings", "*.json")):
            mid = os.path.basename(f)[:-5]; sid = SITE.get(("ea_hydro:guid", gmap.get(mid)))
            if not sid: continue
            isflow = "-flow-" in mid
            rows["hydro:" + mid] = dict(site=sid, param=PARAM["river_flow" if isflow else "rainfall"], src=SRC["ea_hydrology"], agg="mean" if isflow else "sum", interval=86400,
                                        unit="m3_s" if isflow else "mm", native_unit="m3/s" if isflow else "mm", qualifier="qualified", ev="official_monitoring")
            files["hydro:" + mid] = f
        smap = make_series(rows); print("hydrology series", len(smap))
        QM = {"good": "good", "estimated": "estimated", "suspect": "suspect", "unchecked": "unchecked", "missing": "missing"}
        recs = []
        for k, f in files.items():
            sid = smap.get(k)
            if not sid: continue
            for r in json.load(open(f)):
                v = r.get("value")
                try: v = float(v) if v is not None else None
                except Exception: v = None
                vd, inv, mis = (float(r.get(x) or 0) for x in ("valid", "invalid", "missing"))
                comp = vd / (vd + inv + mis) if (vd + inv + mis) > 0 else None
                recs.append((sid, r["dateTime"] + "+00", v, QM.get(str(r.get("quality", "")).lower(), "unchecked") if v is not None else "missing", comp))
        cur.execute("create temp table stg_h (series_id bigint, observed_at timestamptz, value double precision, quality text, completeness real) on commit drop")
        copy_rows(cur, "stg_h", ["series_id", "observed_at", "value", "quality", "completeness"], recs)
        cur.execute("insert into core.observation (series_id, observed_at, value, quality, completeness) select series_id, observed_at, value, quality, completeness from stg_h on conflict do nothing")
        print("hydrology observations", len(recs), round(time.time() - t0, 1), "s")

    # ═════════ NRFA gdf ═════════
    if "nrfa" in which:
        rows, files = {}, {}
        for f in glob.glob(os.path.join(RAW, "nrfa", "gdf", "*.json")):
            nid = os.path.basename(f)[:-5]; sid = SITE.get(("nrfa:id", nid))
            if not sid: continue
            rows[f"nrfa:{nid}:gdf"] = dict(site=sid, param=PARAM["river_flow"], src=SRC["nrfa"], agg="mean", interval=86400, unit="m3_s", native_unit="m3/s", qualifier="gdf", ev="official_monitoring", method="gauged")
            files[f"nrfa:{nid}:gdf"] = f
        smap = make_series(rows); print("nrfa series", len(smap))
        recs = []
        for k, f in files.items():
            sid = smap.get(k); ds = json.load(open(f)).get("data-stream", [])
            for i in range(0, len(ds) - 1, 2):
                if ds[i + 1] is None: continue
                recs.append((sid, ds[i] + " 00:00:00+00", float(ds[i + 1]), "good"))
        cur.execute("create temp table stg_n (series_id bigint, observed_at timestamptz, value double precision, quality text) on commit drop")
        copy_rows(cur, "stg_n", ["series_id", "observed_at", "value", "quality"], recs)
        cur.execute("insert into core.observation (series_id, observed_at, value, quality) select * from stg_n on conflict do nothing")
        print("nrfa observations", len(recs), round(time.time() - t0, 1), "s")

    # ═════════ EA WQ archive ═════════
    if "wq" in which:
        cur.execute("select native_code, parameter_id, unit_id, fraction, method from ref.parameter_alias where source_id=%s and status='mapped'", (SRC["ea_wq_archive"],))
        AL = {c: (p, u, fr, me) for c, p, u, fr, me in cur.fetchall()}
        cur.execute("select id, canonical_unit from ref.parameter"); PU = dict(cur.fetchall())
        frames = []
        for f in sorted(glob.glob(os.path.join(RAW, "ea_wq", "obs", "*.csv.gz"))):
            frames.append(pd.read_csv(f, dtype=str, usecols=["id", "samplingPoint.notation", "phenomenonTime", "samplingPurpose", "sampleMaterialType", "determinand.notation", "result", "unit"]))
        d = pd.concat(frames, ignore_index=True); del frames
        d.columns = ["id", "point", "when", "purpose", "material", "det", "result", "unit"]
        print("wq rows read", len(d), round(time.time() - t0, 1), "s", flush=True)
        d = d[d["det"].isin(AL.keys()) & d["point"].map(lambda p: ("ea_wims:notation", p) in SITE)].copy()
        d["site_id"] = d["point"].map(lambda p: SITE[("ea_wims:notation", p)])
        d["sample_key"] = d["id"].str.extract(r"/sample/([^/]+)/")[0]
        d["observed_at"] = pd.to_datetime(d["when"]).dt.tz_localize("Europe/London", ambiguous="NaT", nonexistent="shift_forward").dt.tz_convert("UTC")
        d = d[d["observed_at"].notna()]
        s = d["result"].str.strip()
        d["censor"] = np.where(s.str.startswith("<"), "<", np.where(s.str.startswith(">"), ">", None))
        num = pd.to_numeric(s.str.lstrip("<>").str.strip(), errors="coerce")
        d["raw"] = np.where(d["censor"].notna() | num.isna(), s, None)
        d["dl"] = np.where(d["censor"].notna(), num, np.nan)
        # unit conversion to the parameter's canonical unit (priority determinands are already canonical; factor guards the rest)
        fac = d["unit"].map(lambda u: UNIT.get(str(u).lower(), (None, np.nan, 0.0))[1]); off = d["unit"].map(lambda u: UNIT.get(str(u).lower(), (None, np.nan, 0.0))[2])
        d["value"] = np.where(d["censor"].isna(), num * fac + off, np.nan)
        d["dl"] = np.where(d["censor"].notna(), d["dl"] * fac, np.nan)
        bad = d["unit"].map(lambda u: str(u).lower() not in UNIT).sum(); print("rows with unknown unit:", bad)
        d = d[d["value"].notna() | d["censor"].notna()]
        d["series_key"] = "wims:" + d["point"] + ":" + d["det"]
        ser = d.drop_duplicates("series_key")[["series_key", "site_id", "det", "unit"]]
        rows = {}
        for k, sid, det, un in ser.itertuples(index=False):
            p, u, fr, me = AL[det]; rows[k] = dict(site=sid, param=p, src=SRC["ea_wq_archive"], agg="instant", interval=None, unit=PU[p], native_unit=un, ev="official_monitoring", fraction=fr, method=me, matrix="river_water")
        smap = make_series(rows); print("wq series", len(smap), round(time.time() - t0, 1), "s", flush=True)
        # samples
        smp = d.drop_duplicates("sample_key")[["sample_key", "site_id", "observed_at", "material", "purpose"]]
        cur.execute("create temp table stg_smp (key text, site_id bigint, at timestamptz, material text, purpose text) on commit drop")
        copy_df(cur, "stg_smp", smp.rename(columns={"sample_key": "key", "observed_at": "at"}))
        cur.execute("insert into core.sample (site_id, source_id, source_sample_key, sampled_at, material, purpose) select site_id, %s, key, at, material, purpose from stg_smp on conflict do nothing", (SRC["ea_wq_archive"],))
        cur.execute("select source_sample_key, id from core.sample where source_id=%s", (SRC["ea_wq_archive"],)); samp = dict(cur.fetchall())
        out = pd.DataFrame({"series_id": d["series_key"].map(smap).astype("int64"), "observed_at": d["observed_at"], "value": d["value"], "censor": d["censor"], "detection_limit": d["dl"],
                            "value_raw": d["raw"], "quality": "unchecked", "sample_id": d["sample_key"].map(samp).astype("Int64")})
        cur.execute("create temp table stg_w (series_id bigint, observed_at timestamptz, value double precision, censor text, detection_limit double precision, value_raw text, quality text, sample_id bigint) on commit drop")
        copy_df(cur, "stg_w", out)
        cur.execute("insert into core.observation (series_id, observed_at, value, censor, detection_limit, value_raw, quality, sample_id) select * from stg_w on conflict do nothing")
        print("wq observations", len(out), "censored", int((out["censor"].notna()).sum()), round(time.time() - t0, 1), "s")

    # rollups
    cur.execute("""insert into core.observation_latest (series_id, observed_at, value, censor, quality)
        select distinct on (series_id) series_id, observed_at, value, censor, quality from core.observation where value is not null or censor is not null order by series_id, observed_at desc
        on conflict (series_id) do update set observed_at = excluded.observed_at, value = excluded.value, censor = excluded.censor, quality = excluded.quality, updated_at = now()""")
    cur.execute("update core.series s set first_at = a.mn, last_at = a.mx from (select series_id, min(observed_at) mn, max(observed_at) mx from core.observation group by 1) a where a.series_id = s.id")
    conn.commit()
    for t in ("series", "sample", "observation", "observation_latest"):
        cur.execute(f"select count(*) from core.{t}"); print(t, cur.fetchone()[0])
print("done", round(time.time() - t0, 1), "s")
