"""Citizen-science surveys (last 36 months), bathing-water samples, EA flood warning areas and warnings in force, determinand catalogue, nutrient neutrality catchments.
Research papers are linked to rivers by link_research.py, straight from the OpenAlex download."""
import json, os, re, time, datetime as dt, collections
from db import *
t0 = time.time()
def feats(p): return json.load(open(os.path.join(RAW, p)))["features"]
def ms(v): return dt.datetime.fromtimestamp(v / 1000, dt.timezone.utc).isoformat() if isinstance(v, (int, float)) and v > 0 else None
def clean(p, drop=()): return {k: v for k, v in p.items() if v not in (None, "", "No") and k not in drop and not k.startswith("Shape__")}

with connect() as conn, conn.cursor() as cur:
    S = lambda s: source_id(cur, s)
    # ── surveys: only what the dossiers count (36 months), placed in a waterbody by their point; Big River Watch keeps only the health answer
    cur.execute("create temp table stg_sv (src bigint, key text, kind text, at text, lon double precision, lat double precision, label text, score numeric, breach boolean, answers text) on commit drop")
    rows = []
    for f in feats("castco/big_river_watch__0.geojson"):
        p = f["properties"]; g = (f.get("geometry") or {}).get("coordinates")
        if not g: continue
        rows.append((S("castco_big_river_watch"), str(p["OBJECTID"]), "big_river_watch", ms(p.get("surveyDate")), g[0], g[1], p.get("health"), None, None, jdump({"health": p.get("health")})))
    for fn, kind in (("riverfly__0", "riverfly_rmi"), ("riverfly_urban__0", "riverfly_urban"), ("riverfly_ext_wq__0", "riverfly_extended_wq"), ("riverfly_ext_silt_flow__0", "riverfly_extended_silt_flow")):
        for f in feats(f"castco/{fn}.geojson"):
            p = f["properties"]; g = (f.get("geometry") or {}).get("coordinates")
            if not g: continue
            br = p.get("breach")
            rows.append((S("castco_riverfly"), f"{kind}:{p['OBJECTID']}", kind, ms(p.get("timestamp")), g[0], g[1], p.get("breachType"), p.get("total"), None if br is None else bool(br), "{}"))
    copy_rows(cur, "stg_sv", ["src", "key", "kind", "at", "lon", "lat", "label", "score", "breach", "answers"], rows)
    cur.execute("""insert into live.survey (source_id, source_key, kind, surveyed_at, waterbody_id, summary_label, summary_score, breach, answers)
        select v.src, v.key, v.kind, v.at::timestamptz,
               (select w.id from geo.waterbody w where w.catchment_geom is not null and ST_Intersects(w.catchment_geom, ST_SetSRID(ST_MakePoint(v.lon, v.lat), 4326)) order by w.area_km2 limit 1),
               v.label, v.score, v.breach, v.answers::jsonb
        from stg_sv v where v.lon between -11 and 3 and v.lat between 49 and 61.5 and v.at::timestamptz > now() - interval '36 months' on conflict do nothing""")
    cur.execute("update live.survey v set river_id = w.river_id from geo.waterbody w where w.id = v.waterbody_id and v.river_id is null")
    cur.execute("select count(*), count(waterbody_id) from live.survey"); print("surveys (total, in waterbody):", cur.fetchone(), round(time.time() - t0, 1), "s")

    # ── bathing samples -> series/observations (archive.py keeps the newest per series)
    cur.execute("select value, site_id from geo.site_key where scheme='eubwid'"); EU = dict(cur.fetchall())
    cur.execute("select code, id from ref.parameter where code in ('ecoli','enterococci')"); P = dict(cur.fetchall())
    samples = json.load(open(os.path.join(RAW, "bathing", "in_season_samples_2023_on.json")))
    v = lambda x: x.get("_value") if isinstance(x, dict) else x
    def cens(q):
        n = (q or {}).get("countQualifierNotation")
        return n if n in ("<", ">") else None
    ser, obs = {}, []
    for x in samples:
        bw = x.get("bwq_bathingWater"); eu = bw.get("eubwidNotation") if isinstance(bw, dict) else (bw.rsplit("/", 1)[-1] if isinstance(bw, str) else None); sid = EU.get(eu)
        if not sid: continue
        at = ((x.get("sampleDateTime") or {}).get("inXSDDateTime") or {}).get("_value")
        if not at: continue
        first = lambda y: (y[0] if y else None) if isinstance(y, list) else y
        for par, cv, cq in (("ecoli", "escherichiaColiCount", "escherichiaColiQualifier"), ("enterococci", "intestinalEnterococciCount", "intestinalEnterococciQualifier")):
            x = dict(x); x[cv] = first(x.get(cv)); x[cq] = first(x.get(cq))
            if x.get(cv) is None: continue
            k = f"bwq:{eu}:{par}"; ser.setdefault(k, (sid, P[par]))
            # a censored count ("<10") keeps its limit as the value, flagged by censor
            obs.append((k, at, float(x[cv]), cens(x.get(cq)), "true" == str(v(x.get("discountable"))).lower()))
    cur.execute("select nextval(pg_get_serial_sequence('live.series','id')) from generate_series(1,%s)", (max(len(ser), 1),)); ids = [r[0] for r in cur.fetchall()]
    cur.execute("create temp table stg_bs (id bigint, site_id bigint, param bigint, key text) on commit drop")
    copy_rows(cur, "stg_bs", ["id", "site_id", "param", "key"], ((i, s, p, k) for i, (k, (s, p)) in zip(ids, ser.items())))
    cur.execute("""insert into live.series (id, site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, evidence_class, matrix, method)
        overriding system value select id, site_id, param, %s, key, 'instant', null, 'per_100ml', 'count/100ml', 'regulator_assessment', 'bathing_water', 'laboratory' from stg_bs on conflict (source_id, source_series_key) do nothing""", (S("ea_bathing"),))
    cur.execute("select source_series_key, id from live.series where source_id=%s", (S("ea_bathing"),)); SM = dict(cur.fetchall())
    cur.execute("create temp table stg_bo (series_id bigint, at text, value double precision, censor text, disc boolean) on commit drop")
    copy_rows(cur, "stg_bo", ["series_id", "at", "value", "censor", "disc"], ((SM[k], a, vv, c, dd) for k, a, vv, c, dd in obs))
    cur.execute("""create temp table stg_bm on commit drop as select series_id, (at::timestamp at time zone 'Europe/London') observed_at, value, case when disc then 'suspect' else 'good' end quality, censor from stg_bo""")
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "etl")); import common
    common.merge_staged(cur, "stg_bm", update=False)
    print("bathing series", len(SM), "obs", len(obs), round(time.time() - t0, 1), "s")

    # ── EA flood warning areas (geometry arrives only while a warning is active: load_flood.py) and the warnings in force
    fa = json.load(open(os.path.join(RAW, "ea_flood", "floodAreas.json")))["items"]
    cur.execute("create temp table stg_fa (code text, name text, kind text) on commit drop")
    copy_rows(cur, "stg_fa", ["code", "name", "kind"], ((a.get("notation") or a.get("fwdCode"), a.get("label") or a.get("description"), "warning" if str(a.get("notation", "")).find("FW") >= 0 else "alert") for a in fa))
    cur.execute("""insert into geo.area (kind, code, name, source_id, attrs) select 'warning_area', code, name, %s, jsonb_build_object('kind', kind) from stg_fa where code is not null
                   on conflict (kind, code) do nothing""", (S("ea_flood_monitoring"),))
    cur.execute("select code, id from geo.area where kind = 'warning_area'"); FA = dict(cur.fetchall())
    n = 0
    for w in json.load(open(os.path.join(RAW, "ea_flood", "floods.json")))["items"]:
        aid = FA.get(w.get("floodAreaID"))
        if not aid: continue
        cur.execute("""insert into live.flood (kind, area_id, severity, message, issued_at, changed_at) values ('warning', %s, %s, %s, %s, %s)
                       on conflict (area_id) where kind = 'warning' do update set severity = excluded.severity, message = excluded.message, changed_at = excluded.changed_at""",
                    (aid, w.get("severityLevel"), w.get("message"), w.get("timeRaised") or None, w.get("timeSeverityChanged") or None)); n += 1
    print("flood areas", len(FA), "warnings", n)

    # ── full determinand catalogue as unmapped aliases (nothing lost)
    dets = json.load(open(os.path.join(RAW, "ea_wq", "codelist_determinand.json")))
    cur.execute("create temp table stg_d (code text, label text) on commit drop")
    copy_rows(cur, "stg_d", ["code", "label"], ((d["notation"], d.get("prefLabel")) for d in dets))
    cur.execute("insert into ref.parameter_alias (source_id, native_code, native_label, status) select %s, code, label, 'unmapped' from stg_d on conflict (source_id, native_code) do nothing", (S("ea_wq_archive"),))
    cur.execute("select status, count(*) from ref.parameter_alias group by 1"); print("aliases:", dict(cur.fetchall()))

    # ── nutrient neutrality catchments (Natural England): an input to the agricultural pressure signal
    nn = feats("ne/nutrient_neutrality_catchments.geojson")
    cur.execute("create temp table stg_nn (code text, name text, g text, attrs text) on commit drop")
    copy_rows(cur, "stg_nn", ["code", "name", "g", "attrs"], ((f["properties"].get("GlobalID") or str(f["properties"]["OBJECTID"]), f["properties"].get("Label") or f["properties"].get("SSSIname"), json.dumps(f["geometry"]),
                                                              jdump({k: f["properties"].get(k) for k in ("N2K_Site_N", "SSSIname", "DateAmend", "Notes", "AreaHa")})) for f in nn if f.get("geometry")))
    cur.execute("""insert into geo.area (kind, code, name, source_id, geom, attrs) select 'nutrient_neutrality', code, name, %s,
        ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)), 3)), attrs::jsonb from stg_nn on conflict (kind, code) do nothing""", (S("ne_nutrient_neutrality"),))
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
