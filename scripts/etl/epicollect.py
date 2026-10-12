"""Wye Alliance + Usk CaSTCo citizen-science readings from their public Epicollect5 projects -> core.site / sample / observation / survey.
Incremental: asks only for entries uploaded since the newest one we hold. First run backfills everything (~25 min at the polite rate).
Units follow the project forms (developers.epicollect.net export API; form questions read from /api/internal/project/<slug>):
  nitrate, nitrite strips   Hach-type strips, mg/L as N                       -> nitrate_n, nitrite_n
  Hanna phosphate checker   reported in ppm as PO4; converted to P (x0.3261), the unconverted number is kept in value_raw
  ammonia (Hanna, strips)   mg/L as N                                          -> ammonia_total_n
Not loaded as series (kept in the survey record): air temperature, strip pH, TDS, strip phosphate, water level (datums differ)."""
import datetime as dt, json, os, re, statistics, sys
os.environ.setdefault("MIN_GAP", "24")                      # the API allows 5 requests/minute; stay near half
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."), os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
from zoneinfo import ZoneInfo
import lib
from db import connect, copy_rows, source_id, start_run, finish_run

API = "https://five.epicollect.net/api/export/entries/"
UK = ZoneInfo("Europe/London")
PO4_TO_P = 0.3261
PROJECTS = {
    "wye": {"slug": "wye-alliance-citizen-science", "source": "epicollect_wye"},
    "usk": {"slug": "usk-castco-citizen-science", "source": "epicollect_usk"},
}

def num(v):
    try:
        x = float(str(v).strip().replace(",", ""))
        return x if x == x else None
    except (TypeError, ValueError): return None

def when(date, time_, fallback):
    try:
        d = dt.datetime.strptime(date, "%d/%m/%Y"); h, m = (int(x) for x in (time_ or "12:00").split(":")[:2])
        return d.replace(hour=h, minute=m, tzinfo=UK).astimezone(dt.timezone.utc)
    except Exception: return dt.datetime.fromisoformat(fallback.replace("Z", "+00:00"))

def site_code(label):
    m = re.search(r"\b([A-Z]{3,5}\d{2,3})\b", label or "")
    return m.group(1) if m else (label or "").strip()

def parse(project, e):
    """-> dict(site_key, site_name, lat, lon, at, measures[(param, method, value, raw)], survey_answers, usable) or None for tests."""
    if project == "wye":
        label = next((e.get(k) for k in ("3_Please_pick_your_s", "4_Please_pick_your_s", "5_Please_pick_your_s", "6_Please_pick_your_s") if e.get(k)), "")
        loc = e.get("8_Sample_site_locati") or {}; at = when(e.get("10_Sample_date"), e.get("11_Sample_time"), e["created_at"]); safe = e.get("12_Please_confirm_yo") != "No"
        m = [("turbidity", "meter", num(e.get("16_Turbidity_value_i")), e.get("16_Turbidity_value_i")),
             ("nitrate_n", "strip", num(e.get("18_Nitrate_level_via")), e.get("18_Nitrate_level_via")),
             ("nitrite_n", "strip", num(e.get("19_Nitrite_level_via")), e.get("19_Nitrite_level_via")),
             ("conductivity", "meter", num(e.get("22_Electrical_conduc")), e.get("22_Electrical_conduc")),
             ("water_temperature", "meter", num(e.get("24_Temperature_C")), e.get("24_Temperature_C")),
             ("ph", "meter", num(e.get("25_pH_via_HM_DIGITAL")), e.get("25_pH_via_HM_DIGITAL")),
             ("phosphorus_reactive", "hanna_po4", num(e.get("27_Phosphate_level_v")), e.get("27_Phosphate_level_v")),
             ("ammonia_total_n", "hanna", num(e.get("28_Ammoniacal_Nitrog")), e.get("28_Ammoniacal_Nitrog"))]
        org = e.get("2_Which_organisation")
    else:
        label = e.get("Site") or ""; loc = e.get("Site_Location") or {}; at = when(e.get("Date"), e.get("Time"), e["created_at"]); safe = e.get("Safe") != "No"
        ec = [x for x in (num(e.get("EC_1")), num(e.get("EC_2")), num(e.get("EC_3"))) if x is not None]
        m = [("turbidity", "meter", num(e.get("Turbidity_1")), e.get("Turbidity_1")),
             ("nitrate_n", "strip", num(e.get("Nitrate")), e.get("Nitrate")), ("nitrite_n", "strip", num(e.get("Nitrite")), e.get("Nitrite")),
             ("conductivity", "meter", statistics.mean(ec) if ec else None, ",".join(str(x) for x in ec)),
             ("water_temperature", "meter", num(e.get("Temp_meter")), e.get("Temp_meter")),
             ("phosphorus_reactive", "hanna_po4", num(e.get("Phosphate_Hanna")), e.get("Phosphate_Hanna")),
             ("ammonia_total_n", "hanna", num(e.get("Ammonium_Hanna")), e.get("Ammonium_Hanna")), ("ammonia_total_n", "strip", num(e.get("Total_Ammonia")), e.get("Total_Ammonia"))]
        org = (e.get("Organisation") or "").strip() or None
    if not label or re.search(r"(?i)\b[A-Z]{3,5}0{3}\b|test|training", label) or str(e.get("1_What_is_your_citiz", e.get("CS_ID", ""))).strip() == "0": return None
    la, lo = num(loc.get("latitude")), num(loc.get("longitude"))
    if la is None or lo is None or not (49 <= la <= 61 and -8.5 <= lo <= 2): la = lo = None
    code = site_code(label)
    m = [(p, meth, v * PO4_TO_P if meth == "hanna_po4" else v, raw) for p, meth, v, raw in m if v is not None] if safe else []
    skip = {"created_at", "uploaded_at", "title", "ec5_uuid"}
    ans = {k: v for k, v in e.items() if k not in skip and v not in ("", [], None) and not (isinstance(v, dict) and not any(v.values()))}
    ans["uploaded_at"] = e["uploaded_at"]
    return dict(key=f"{project}:{code}", name=label, org=org, lat=la, lon=lo, at=at, measures=m, answers=ans, uuid=e["ec5_uuid"], safe=safe)

def fetch(slug, since):
    page, out = 1, []
    while True:
        q = f"{API}{slug}?per_page=500&page={page}&sort_order=ASC" + (f"&filter_by=uploaded_at&filter_from={since}" if since else "")
        os.makedirs(os.path.join(lib.ROOT, "epicollect"), exist_ok=True)
        f = os.path.join(lib.ROOT, "epicollect", f"{slug}_{(since or 'all').replace(':', '')}_p{page}.json")
        if since is None and os.path.exists(f) and page > 1: j = json.load(open(f))        # resume a backfill from the pages already on disk
        else:
            r = lib.get(q, timeout=300); open(f, "wb").write(r.content); j = r.json()
        es = j["data"]["entries"]
        out += es; print(f"  {slug} page {page}/{j['meta']['last_page']}: {len(es)} entries", flush=True)
        if page >= j["meta"]["last_page"] or not es: return out
        page += 1

with connect() as conn, conn.cursor() as cur:
    cur.execute("select code, id from ref.parameter"); PID = dict(cur.fetchall())
    cur.execute("select id, canonical_unit from ref.parameter"); UNIT = {pid: u for pid, u in cur.fetchall()}
    tot = dict(entries=0, obs=0, new_sites=0, rejected=0)
    for project, cfg in PROJECTS.items():
        S = source_id(cur, cfg["source"]); run = start_run(cur, cfg["source"], "epicollect", {"project": cfg["slug"]})
        cur.execute("select max(answers->>'uploaded_at') from core.survey where source_id = %s", (S,)); since = cur.fetchone()[0]
        entries = fetch(cfg["slug"], since)
        parsed = [p for p in (parse(project, e) for e in entries) if p]
        # sites: coordinates learned from every entry that has them (volunteers only fill the location when at the site)
        coords = {}
        for p in parsed:
            if p["lat"] is not None: coords.setdefault(p["key"], []).append((p["lat"], p["lon"]))
        cur.execute("select value, site_id from core.site_identifier where scheme = %s", (f"epicollect:{project}",)); SITE = dict(cur.fetchall())
        names = {p["key"]: p for p in parsed}
        for key, p in names.items():
            code = key.split(":", 1)[1]
            if code in SITE or key not in coords: continue
            la = statistics.median(c[0] for c in coords[key]); lo = statistics.median(c[1] for c in coords[key])
            cur.execute("""insert into core.site (kind, name, geom, geom_bng, country, status, primary_source_id, attrs)
                           values ('survey_site', %s, ST_SetSRID(ST_MakePoint(%s, %s), 4326), ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 27700), (select case b.name when 'England' then 'ENG' when 'Wales' then 'WLS' when 'Scotland' then 'SCT' end from core.boundary b where b.kind = 'country' and ST_Intersects(b.geom_lo, ST_SetSRID(ST_MakePoint(%s, %s), 4326)) limit 1), 'active', %s, %s) returning id""",
                        (p["name"], lo, la, lo, la, lo, la, S, json.dumps({"code": code, "organisation": p["org"], "project": cfg["slug"]})))
            sid = cur.fetchone()[0]; SITE[code] = sid; tot["new_sites"] += 1
            cur.execute("insert into core.site_identifier (scheme, value, site_id, source_id) values (%s, %s, %s, %s) on conflict do nothing", (f"epicollect:{project}", code, sid, S))
            cur.execute("""with n as (select l.id, l.river_id, l.waterbody_id, l.length_m, l.dist_to_mouth_m, ST_Distance(s.geom_bng, l.geom_bng) d, ST_LineLocatePoint(l.geom_bng, s.geom_bng) frac
                                      from core.site s cross join lateral (select * from core.river_link order by geom_bng <-> s.geom_bng limit 1) l where s.id = %s)
                           update core.site s set snap_distance_m = n.d, river_link_id = case when n.d <= 500 then n.id end, river_id = case when n.d <= 500 then n.river_id end,
                                  waterbody_id = coalesce(case when n.d <= 500 then n.waterbody_id end, (select w.id from core.waterbody w where w.catchment_geom is not null and ST_Intersects(w.catchment_geom, s.geom) order by w.area_km2 limit 1)),
                                  dist_to_mouth_m = case when n.d <= 500 then greatest(0, n.dist_to_mouth_m - n.frac * coalesce(n.length_m, 0)) end from n where s.id = %s""", (sid, sid))
        usable = [p for p in parsed if p["key"].split(":", 1)[1] in SITE]; tot["rejected"] += len(parsed) - len(usable)
        # surveys + samples
        for p in usable:
            sid = SITE[p["key"].split(":", 1)[1]]
            cur.execute("insert into core.survey (source_id, source_key, kind, site_id, surveyed_at, answers, evidence_class) values (%s, %s, 'citizen_weekly', %s, %s, %s, 'citizen_science') on conflict do nothing",
                        (S, p["uuid"], sid, p["at"], json.dumps(p["answers"])))
            if not p["measures"]: continue
            cur.execute("insert into core.sample (site_id, source_id, source_sample_key, sampled_at, material, purpose) values (%s, %s, %s, %s, 'river_water', 'citizen_science') on conflict do nothing returning id", (sid, S, p["uuid"], p["at"]))
            r = cur.fetchone()
            if r is None: cur.execute("select id from core.sample where source_id = %s and source_sample_key = %s", (S, p["uuid"])); r = cur.fetchone()
            p["sample"] = r[0]; p["site"] = sid
        # series + observations
        cur.execute("select source_series_key, id from core.series where source_id = %s", (S,)); SER = dict(cur.fetchall())
        rows = []
        for p in usable:
            if "sample" not in p: continue
            for param, meth, v, raw in p["measures"]:
                key = f"epi:{p['key']}:{param}:{meth}"
                if key not in SER:
                    cur.execute("""insert into core.series (site_id, parameter_id, source_id, source_series_key, aggregation, interval_s, unit_id, qualifier, matrix, method, evidence_class, is_preferred)
                                   values (%s, %s, %s, %s, 'instant', null, %s, %s, 'river_water', %s, 'citizen_science', false) on conflict do nothing returning id""",
                                (p["site"], PID[param], S, key, UNIT[PID[param]], meth, meth))
                    x = cur.fetchone()
                    if x is None: cur.execute("select id from core.series where source_id = %s and source_series_key = %s", (S, key)); x = cur.fetchone()
                    SER[key] = x[0]
                rows.append((SER[key], p["at"], v, str(raw), "unchecked", p["sample"]))
        cur.execute("create temp table stg_e (series_id bigint, observed_at timestamptz, value float8, value_raw text, quality text, sample_id bigint) on commit drop")
        copy_rows(cur, "stg_e", ["series_id", "observed_at", "value", "value_raw", "quality", "sample_id"], rows)
        cur.execute("insert into core.observation (series_id, observed_at, value, value_raw, quality, sample_id) select * from stg_e on conflict do nothing")
        cur.execute("""insert into core.observation_latest (series_id, observed_at, value, quality) select distinct on (series_id) series_id, observed_at, value, quality from stg_e order by series_id, observed_at desc
                       on conflict (series_id) do update set observed_at = excluded.observed_at, value = excluded.value, quality = excluded.quality, updated_at = now() where excluded.observed_at > core.observation_latest.observed_at""")
        cur.execute("""update core.series s set first_at = least(coalesce(s.first_at, x.a), x.a), last_at = greatest(coalesce(s.last_at, x.b), x.b) from (select series_id, min(observed_at) a, max(observed_at) b from stg_e group by 1) x where x.series_id = s.id""")
        if rows: cur.execute("select ops.flag_implausible((select min(observed_at) from stg_e))")
        finish_run(cur, run, read=len(entries), written=len(rows), rejected=len(parsed) - len(usable)); conn.commit()
        tot["entries"] += len(entries); tot["obs"] += len(rows)
        print(f"{project}: {len(entries)} entries, {len(parsed)} real visits, {len(rows)} readings", flush=True)
    print(tot)
