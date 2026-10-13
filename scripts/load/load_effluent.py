"""Final-effluent monitoring at water-company works -> live.series (matrix 'effluent', evidence 'company_reported') + observations."""
import glob, gzip, io, os, sys, time
import numpy as np, pandas as pd
from db import *
t0 = time.time()
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "ea_wq_archive")
    cur.execute("select value, site_id from geo.site_key where scheme = 'ea_wims:notation'"); SITE = dict(cur.fetchall())
    cur.execute("select native_code, parameter_id from ref.parameter_alias where source_id = %s and status = 'mapped'", (src,)); AL = dict(cur.fetchall())
    cur.execute("select id, canonical_unit from ref.parameter"); PU = dict(cur.fetchall())
    cur.execute("select id, aliases, factor, \"offset\" from ref.unit"); UNIT = {}
    for uid, al, f, o in cur.fetchall():
        UNIT[uid.lower()] = (float(f), float(o))
        for a in al: UNIT[a.lower()] = (float(f), float(o))
    frames = [pd.read_csv(f, dtype=str, usecols=["samplingPoint.notation", "phenomenonTime", "determinand.notation", "result", "unit"]) for f in sorted(glob.glob(os.path.join(RAW, "ea_wq", "effluent", "*.csv.gz")))]
    d = pd.concat(frames, ignore_index=True); d.columns = ["point", "when", "det", "result", "unit"]; print("rows read", len(d))
    d = d[d["det"].isin(AL.keys()) & d["point"].isin(SITE.keys())].copy()
    d["site_id"] = d["point"].map(SITE)
    d["observed_at"] = pd.to_datetime(d["when"]).dt.tz_localize("Europe/London", ambiguous="NaT", nonexistent="shift_forward").dt.tz_convert("UTC"); d = d[d["observed_at"].notna()]
    s = d["result"].str.strip(); d["censor"] = np.where(s.str.startswith("<"), "<", np.where(s.str.startswith(">"), ">", None))
    num = pd.to_numeric(s.str.lstrip("<>").str.strip(), errors="coerce")
    fac = d["unit"].map(lambda u: UNIT.get(str(u).lower(), (1.0, 0.0))[0]); off = d["unit"].map(lambda u: UNIT.get(str(u).lower(), (1.0, 0.0))[1])
    d["value"] = np.where(d["censor"].isna(), num * fac + off, np.nan); d["dl"] = np.where(d["censor"].notna(), num * fac, np.nan)
    d["raw"] = np.where(d["censor"].notna() | num.isna(), s, None); d = d[d["value"].notna() | d["censor"].notna()]
    d["key"] = "wims-eff:" + d["point"] + ":" + d["det"]
    ser = d.drop_duplicates("key")[["key", "site_id", "det", "unit"]]
    cur.execute("select nextval(pg_get_serial_sequence('live.series','id')) from generate_series(1,%s)", (max(len(ser), 1),)); ids = [r[0] for r in cur.fetchall()]
    cur.execute("create temp table stg_s (id bigint, site bigint, param bigint, key text, unit text, nunit text) on commit drop")
    copy_rows(cur, "stg_s", ["id", "site", "param", "key", "unit", "nunit"], ((i, int(r.site_id), AL[r.det], r.key, PU[AL[r.det]], r.unit) for i, r in zip(ids, ser.itertuples(index=False))))
    cur.execute("""insert into live.series (id, site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, evidence_class, matrix, method)
        overriding system value select id, site, param, %s, key, 'instant', null, unit, nunit, 'company_reported', 'effluent', 'operator self-monitoring' from stg_s on conflict (source_id, source_series_key) do nothing""", (src,))
    cur.execute("select source_series_key, id from live.series where source_id = %s and matrix = 'effluent'", (src,)); SM = dict(cur.fetchall())
    # a censored result ("<5") keeps its detection limit as the value
    out = pd.DataFrame({"series_id": d["key"].map(SM).astype("int64"), "observed_at": d["observed_at"], "value": d["value"].where(d["value"].notna() | d["censor"].isna(), d["dl"]), "quality": "unchecked", "censor": d["censor"]})
    cur.execute("create temp table stg_o (series_id bigint, observed_at timestamptz, value float8, quality text, censor text) on commit drop")
    buf = io.StringIO(); out.to_csv(buf, index=False, header=False, na_rep="\\N"); buf.seek(0)
    with cur.copy("copy stg_o from stdin with (format csv, null '\\N')") as cp:
        while chunk := buf.read(1 << 22): cp.write(chunk)
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "etl")); import common
    common.merge_staged(cur, "stg_o", update=False)
    print("effluent series", len(SM), "observations", len(out), "points with data", d["point"].nunique(), round(time.time() - t0, 1), "s")
    cur.execute("select live.refresh_works()"); cur.execute("select count(*) filter (where n.site_id is not null), count(*) filter (where (s.attrs->>'measured')::boolean), count(*) from geo.site s left join live.site_now n on n.site_id = s.id and n.kind = 'works' where s.kind = 'sewage_works' and s.attrs ? 'works'"); print("works (with latest, measured, total):", cur.fetchone())
    conn.commit()
