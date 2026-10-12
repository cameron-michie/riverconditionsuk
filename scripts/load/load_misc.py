"""Surveys, incidents, obstacles, bathing samples, flood warnings, research, determinand catalogue, NN zones, provenance manifest."""
import json, os, re, time, datetime as dt, collections
from db import *
t0 = time.time()
def feats(p): return json.load(open(os.path.join(RAW, p)))["features"]
def ms(v): return dt.datetime.fromtimestamp(v / 1000, dt.timezone.utc).isoformat() if isinstance(v, (int, float)) and v > 0 else None
def clean(p, drop=()): return {k: v for k, v in p.items() if v not in (None, "", "No") and k not in drop and not k.startswith("Shape__")}

with connect() as conn, conn.cursor() as cur:
    S = lambda s: source_id(cur, s)
    # ── surveys
    cur.execute("create temp table stg_sv (src bigint, key text, kind text, at text, lon double precision, lat double precision, label text, score numeric, breach boolean, answers text) on commit drop")
    rows = []
    for f in feats("castco/big_river_watch__0.geojson"):
        p = f["properties"]; g = (f.get("geometry") or {}).get("coordinates")
        if not g: continue
        rows.append((S("castco_big_river_watch"), str(p["OBJECTID"]), "big_river_watch", ms(p.get("surveyDate")), g[0], g[1], p.get("health"), None, None, jdump(clean(p, ("OBJECTID", "GlobalID", "CreationDate", "Creator", "EditDate", "Editor", "latitude", "longitude")))))
    for fn, kind in (("riverfly__0", "riverfly_rmi"), ("riverfly_urban__0", "riverfly_urban"), ("riverfly_ext_wq__0", "riverfly_extended_wq"), ("riverfly_ext_silt_flow__0", "riverfly_extended_silt_flow")):
        for f in feats(f"castco/{fn}.geojson"):
            p = f["properties"]; g = (f.get("geometry") or {}).get("coordinates")
            if not g: continue
            br = p.get("breach")
            rows.append((S("castco_riverfly"), f"{kind}:{p['OBJECTID']}", kind, ms(p.get("timestamp")), g[0], g[1], p.get("breachType"), p.get("total"), None if br is None else bool(br),
                         jdump(clean(p, ("OBJECTID", "cartographerId", "featureId", "projectId", "teamId", "surveyId", "timestamp", "fixedPointPhotographs", "breachPhotographs")))))
    copy_rows(cur, "stg_sv", ["src", "key", "kind", "at", "lon", "lat", "label", "score", "breach", "answers"], rows)
    cur.execute("""insert into core.survey (source_id, source_key, kind, surveyed_at, geom, summary_label, summary_score, breach, answers)
        select src, key, kind, at::timestamptz, ST_SetSRID(ST_MakePoint(lon, lat), 4326), label, score, breach, answers::jsonb from stg_sv where lon between -11 and 3 and lat between 49 and 61.5 on conflict do nothing""")
    cur.execute("""update core.survey s set waterbody_id = w.id from (
        select distinct on (s2.id) s2.id sid, w2.id from core.survey s2 join core.waterbody w2 on w2.catchment_geom is not null and ST_Intersects(w2.catchment_geom, s2.geom)
        where s2.waterbody_id is null order by s2.id, w2.area_km2) w where w.sid = s.id""")
    cur.execute("select count(*), count(waterbody_id) from core.survey"); print("surveys (total, in waterbody):", cur.fetchone(), round(time.time() - t0, 1), "s")

    # ── pollution incidents
    cur.execute("create temp table stg_pi (key text, cat text, pol text, ws smallint, ls smallint, aus smallint, lon double precision, lat double precision, attrs text) on commit drop")
    sev = lambda v: int(m.group(1)) if v and (m := re.search(r"Category (\d)", v)) else None
    rows = []
    for f in feats("castco/pollution_incidents_cat1_2__0.geojson"):
        p = f["properties"]; g = (f.get("geometry") or {}).get("coordinates")
        if g: rows.append((str(p["NOT_ID"]), p.get("POLL_TYPE"), p.get("POLLUTANT"), sev(p.get("EIL_WATER")), sev(p.get("EIL_LAND")), sev(p.get("EIL_AIR")), g[0], g[1], jdump({k: p.get(k) for k in ("REGION_WM", "AREA_WM", "COUNTY", "DISTRICT", "CaBACatchment", "CaBAPartnership", "EP_INC")})))
    copy_rows(cur, "stg_pi", ["key", "cat", "pol", "ws", "ls", "aus", "lon", "lat", "attrs"], rows)
    cur.execute("""insert into core.pollution_incident (source_id, source_key, category, pollutant, water_severity, land_severity, air_severity, geom, attrs)
        select %s, key, cat, pol, ws, ls, aus, ST_SetSRID(ST_MakePoint(lon, lat), 4326), attrs::jsonb from stg_pi on conflict do nothing""", (S("castco_pressures"),))
    cur.execute("""update core.pollution_incident i set waterbody_id = w.id from (select distinct on (i2.id) i2.id iid, w2.id from core.pollution_incident i2 join core.waterbody w2 on w2.catchment_geom is not null and ST_Intersects(w2.catchment_geom, i2.geom) order by i2.id, w2.area_km2) w where w.iid = i.id""")
    # ── obstacles
    cur.execute("create temp table stg_ob (key text, typ text, origin text, fp text, h numeric, lon double precision, lat double precision, attrs text) on commit drop")
    rows = []
    for f in feats("castco/river_obstacles__0.geojson"):
        p = f["properties"]; g = (f.get("geometry") or {}).get("coordinates")
        if g: rows.append((str(p["OBJECTID"]), p.get("obstacle_type"), p.get("origin"), p.get("fish_pass"), (p.get("height") if isinstance(p.get("height"), (int, float)) else None), g[0], g[1], jdump(clean(p, ("OBJECTID", "easting", "northing", "gridrefuk")))))
    copy_rows(cur, "stg_ob", ["key", "typ", "origin", "fp", "h", "lon", "lat", "attrs"], rows)
    cur.execute("insert into core.river_obstacle (source_id, source_key, obstacle_type, origin, fish_pass, height_m, geom, attrs) select %s, key, typ, origin, fp, h, ST_SetSRID(ST_MakePoint(lon, lat), 4326), attrs::jsonb from stg_ob on conflict do nothing", (S("castco_pressures"),))
    cur.execute("""update core.river_obstacle o set waterbody_id = w.id from (select distinct on (o2.id) o2.id oid, w2.id from core.river_obstacle o2 join core.waterbody w2 on w2.catchment_geom is not null and ST_Intersects(w2.catchment_geom, o2.geom) order by o2.id, w2.area_km2) w where w.oid = o.id""")
    cur.execute("select (select count(*) from core.pollution_incident), (select count(*) from core.river_obstacle)"); print("incidents, obstacles:", cur.fetchone())

    # ── bathing samples -> series/observations
    cur.execute("select value, site_id from core.site_identifier where scheme='eubwid'"); EU = dict(cur.fetchall())
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
            obs.append((k, at, float(x[cv]) if not cens(x.get(cq)) else None, cens(x.get(cq)), float(x[cv]) if cens(x.get(cq)) else None, "true" == str(v(x.get("discountable"))).lower()))
    cur.execute("select nextval(pg_get_serial_sequence('core.series','id')) from generate_series(1,%s)", (max(len(ser), 1),)); ids = [r[0] for r in cur.fetchall()]
    cur.execute("create temp table stg_bs (id bigint, site_id bigint, param bigint, key text) on commit drop")
    copy_rows(cur, "stg_bs", ["id", "site_id", "param", "key"], ((i, s, p, k) for i, (k, (s, p)) in zip(ids, ser.items())))
    cur.execute("""insert into core.series (id, site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, native_unit, evidence_class, matrix, method)
        overriding system value select id, site_id, param, %s, key, 'instant', null, 'per_100ml', 'count/100ml', 'regulator_assessment', 'bathing_water', 'laboratory' from stg_bs on conflict (source_id, source_series_key) do nothing""", (S("ea_bathing"),))
    cur.execute("select source_series_key, id from core.series where source_id=%s", (S("ea_bathing"),)); SM = dict(cur.fetchall())
    cur.execute("create temp table stg_bo (sid bigint, at text, val double precision, cen text, dl double precision, disc boolean) on commit drop")
    copy_rows(cur, "stg_bo", ["sid", "at", "val", "cen", "dl", "disc"], ((SM[k], a, vv, c, d, dd) for k, a, vv, c, d, dd in obs))
    cur.execute("""insert into core.observation (series_id, observed_at, value, censor, detection_limit, quality)
        select sid, (at::timestamp at time zone 'Europe/London'), val, cen, dl, case when disc then 'suspect' else 'good' end from stg_bo on conflict do nothing""")
    print("bathing series", len(SM), "obs", len(obs), round(time.time() - t0, 1), "s")

    # ── flood areas & active warnings
    fa = json.load(open(os.path.join(RAW, "ea_flood", "floodAreas.json")))["items"]
    cur.execute("create temp table stg_fa (code text, name text, kind text, lon double precision, lat double precision) on commit drop")
    copy_rows(cur, "stg_fa", ["code", "name", "kind", "lon", "lat"], ((a.get("notation") or a.get("fwdCode"), a.get("label") or a.get("description"), "warning" if str(a.get("notation", "")).find("FW") >= 0 else "alert", a.get("long"), a.get("lat")) for a in fa))
    cur.execute("insert into core.flood_area (code, name, kind, source_id) select code, name, kind, %s from stg_fa where code is not null on conflict (code) do nothing", (S("ea_flood_monitoring"),))
    cur.execute("select code, id from core.flood_area"); FA = dict(cur.fetchall())
    n = 0
    for w in json.load(open(os.path.join(RAW, "ea_flood", "floods.json")))["items"]:
        aid = FA.get(w.get("floodAreaID"))
        if not aid: continue
        cur.execute("insert into core.flood_warning (area_id, severity_level, message, raised_at, changed_at, fetched_at, source_id) values (%s,%s,%s,%s,%s,now(),%s) on conflict do nothing",
                    (aid, w.get("severityLevel"), w.get("message"), w.get("timeRaised") or None, w.get("timeSeverityChanged") or None, S("ea_flood_monitoring"))); n += 1
    print("flood areas", len(FA), "warnings", n)

    # ── research library
    works = json.load(open(os.path.join(RAW, "research", "openalex_works.json")))
    cur.execute("create temp table stg_w (oid text, doi text, title text, yr smallint, pdate text, typ text, lang text, venue text, authors text, abs text, rights text, oa text, lic text, landing text, pdf text, cited int, topics text[], found text[]) on commit drop")
    def abstract(ix):
        if not ix: return None
        pos = {}
        for w, ps in ix.items():
            for p in ps: pos[p] = w
        return " ".join(pos[k] for k in sorted(pos))
    rows = []; rights = collections.Counter()
    for w in works:
        loc = w.get("best_oa_location") or w.get("primary_location") or {}; prim = w.get("primary_location") or {}
        lic = (loc.get("license") or prim.get("license") or "") or None
        ab = abstract(w.get("abstract_inverted_index"))
        oa = (w.get("open_access") or {}).get("oa_status")
        r = "full" if ab and lic and lic.startswith(("cc-by", "cc0")) and "nc" not in lic and "nd" not in lic else ("quote_only" if ab else "none")
        rights[r] += 1
        rows.append((w["id"], w.get("doi"), w.get("title") or w.get("display_name") or "(untitled)", w.get("publication_year"), w.get("publication_date"), w.get("type"), w.get("language"),
                     ((prim.get("source") or {}).get("display_name")), jdump([{"name": (a.get("author") or {}).get("display_name"), "orcid": (a.get("author") or {}).get("orcid")} for a in (w.get("authorships") or [])[:30]]),
                     ab if r == "full" else None, r, oa, lic, prim.get("landing_page_url"), loc.get("pdf_url"), w.get("cited_by_count"), [t.get("display_name") for t in (w.get("topics") or [])[:6]], w.get("_queries") or []))
    copy_rows(cur, "stg_w", ["oid", "doi", "title", "yr", "pdate", "typ", "lang", "venue", "authors", "abs", "rights", "oa", "lic", "landing", "pdf", "cited", "topics", "found"], rows)
    cur.execute("""insert into research.work (openalex_id, doi, title, pub_year, pub_date, work_type, language, venue, authors, abstract, abstract_rights, oa_status, licence, landing_url, pdf_url, cited_by, topics, found_by, source_id)
        select oid, doi, title, yr, pdate::date, typ, lang, venue, authors::jsonb, abs, rights, oa, lic, landing, pdf, cited, topics, found, %s from stg_w on conflict (openalex_id) do nothing""", (S("openalex"),))
    print("research works", len(rows), dict(rights), round(time.time() - t0, 1), "s")

    # ── full determinand catalogue as unmapped aliases (nothing lost)
    dets = json.load(open(os.path.join(RAW, "ea_wq", "codelist_determinand.json")))
    cur.execute("create temp table stg_d (code text, label text) on commit drop")
    copy_rows(cur, "stg_d", ["code", "label"], ((d["notation"], d.get("prefLabel")) for d in dets))
    cur.execute("insert into ref.parameter_alias (source_id, native_code, native_label, status) select %s, code, label, 'unmapped' from stg_d on conflict (source_id, native_code) do nothing", (S("ea_wq_archive"),))
    cur.execute("select status, count(*) from ref.parameter_alias group by 1"); print("aliases:", dict(cur.fetchall()))

    # ── nutrient neutrality zones
    nn = feats("ne/nutrient_neutrality_catchments.geojson")
    cur.execute("create temp table stg_nn (code text, name text, g text, attrs text) on commit drop")
    copy_rows(cur, "stg_nn", ["code", "name", "g", "attrs"], ((f["properties"].get("GlobalID") or str(f["properties"]["OBJECTID"]), f["properties"].get("Label") or f["properties"].get("SSSIname"), json.dumps(f["geometry"]), jdump({k: f["properties"].get(k) for k in ("N2K_Site_N", "SSSIname", "DateAmend", "Notes", "AreaHa")})) for f in nn if f.get("geometry")))
    cur.execute("""insert into core.catchment (kind, code, name, country, source_id, geom, attrs) select 'nutrient_neutrality', code, name, 'ENG', %s,
        ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)), 3)), attrs::jsonb from stg_nn on conflict (kind, code) do nothing""", (S("ne_nutrient_neutrality"),))

    # ── provenance manifest -> ingest.raw_object
    SRCMAP = {"ea_flood": "ea_flood_monitoring", "ea_hydrology": "ea_hydrology", "nrfa": "nrfa", "ea_wq": "ea_wq_archive", "bathing": "ea_bathing", "sepa": "sepa_kiwis", "research": "openalex", "cde": "ea_cde_rnag", "ne": "ne_nutrient_neutrality", "wfd": "nrw_datamap_wfs"}
    def src_for(rec):
        d, f = rec["source"], rec["file"].split("/", 1)[1]
        if d == "sewage":
            return "nsoh_scotland" if "scottish" in f else "nsoh_england" if f.startswith("nsoh/") else "rt_edm_annual_ew" if f.startswith("annual/") else "ea_edm_annual"
        if d == "castco":
            b = f.split("__")[0]
            return "castco_wfd_c4" if b.startswith("wfd_c4") or b.startswith("wfd_c3") else "castco_separate" if b.startswith("sources_") else "castco_big_river_watch" if b == "big_river_watch" else "castco_riverfly" if b.startswith("riverfly") else "castco_pressures"
        return SRCMAP.get(d)
    cur.execute("select slug, id from ingest.source"); SID = dict(cur.fetchall())
    cur.execute("create temp table stg_ro (src bigint, path text, url text, sha text, bytes bigint, at timestamptz, note text) on commit drop")
    seen, rows = set(), []
    for line in open(os.path.join(RAW, "manifest.jsonl")):
        r = json.loads(line); s = src_for(r)
        if s not in SID or (r["file"], r["sha256"]) in seen: continue
        seen.add((r["file"], r["sha256"])); rows.append((SID[s], r["file"], r["url"], r["sha256"], r["bytes"], r["fetched_at"], r.get("note")))
    copy_rows(cur, "stg_ro", ["src", "path", "url", "sha", "bytes", "at", "note"], rows)
    cur.execute("insert into ingest.raw_object (source_id, path, url, sha256, bytes, fetched_at, note) select src, path, url, sha, bytes, at, note from stg_ro on conflict do nothing")
    cur.execute("select count(*), pg_size_pretty(sum(bytes)) from ingest.raw_object"); print("raw objects:", cur.fetchone())
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
