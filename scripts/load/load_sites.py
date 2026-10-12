"""Sites from every network, resolved on exact shared identifiers at load time (phase 1 of entity resolution)."""
import json, glob, os, re, time, collections, gzip
from db import *
t0 = time.time()
def L(p): return json.load(open(os.path.join(RAW, p)))
def lower(x): return x.lower() if isinstance(x, str) else x
STATUS = {"statusactive": "active", "statussuspended": "suspended", "statusclosed": "closed"}

with connect() as conn, conn.cursor() as cur:
    S = {s: source_id(cur, s) for s in ("ea_flood_monitoring", "ea_hydrology", "nrfa", "sepa_kiwis", "ea_wq_archive", "ea_edm_annual", "nsoh_england", "nsoh_scotland", "ea_bathing", "castco_pressures")}
    cur.execute("select slug, id, aliases, name from ref.organisation"); ORG = {}
    for slug, i, al, nm in cur.fetchall():
        for a in [nm, slug] + list(al): ORG[a.lower()] = i
    sites = {}                 # id -> dict
    ident = {}                 # (scheme, value) -> (site_id, source, method, conf)
    def alloc(n):
        cur.execute("select nextval(pg_get_serial_sequence('core.site','id')) from generate_series(1,%s)", (n,)); return [r[0] for r in cur.fetchall()]
    pool = alloc(400000); pool.reverse()
    stats = collections.Counter()
    def site(kind, name, lon, lat, ids, src, country=None, status="unknown", opened=None, closed=None, river=None, operator=None, attrs=None, method="native"):
        flat = []
        for a, bv in ids:
            for x in (bv if isinstance(bv, list) else [bv]):
                if x not in (None, "", "None"): flat.append((a, str(x)))
        ids = flat
        if isinstance(lon, list): lon = lon[0] if lon else None
        if isinstance(lat, list): lat = lat[0] if lat else None
        hit = next((ident[i][0] for i in ids if i in ident), None)
        if hit is None:
            if lon is None or lat is None: return None
            hit = pool.pop(); stats["new:" + kind] += 1
            sites[hit] = dict(kind=kind, name=name, lon=lon, lat=lat, country=country, status=status, opened=opened, closed=closed, river=river, operator=operator, src=src, attrs=dict(attrs or {}))
        else:
            stats["merged:" + kind] += 1
            d = sites[hit]
            for k, v in (("name", name), ("country", country), ("river", river), ("opened", opened), ("closed", closed), ("operator", operator)):
                if d.get(k) in (None, "") and v: d[k] = v
            if d["status"] == "unknown" and status != "unknown": d["status"] = status
            for k, v in (attrs or {}).items(): d["attrs"].setdefault(k, v)
        for i in ids:
            if i not in ident: ident[i] = (hit, src, "native" if method == "native" else method, 1.0)
        return hit

    # ── EA flood-monitoring stations
    for st in L("ea_flood/stations.json")["items"]:
        params = {m.get("parameter") for m in st.get("measures", [])}
        kind = "rain_gauge" if params <= {"rainfall"} and params else ("weather_station" if params and params <= {"temperature", "wind"} else "river_gauge")
        w = st.get("wiskiID"); w = w if isinstance(w, str) else None
        site(kind, st.get("label"), st.get("long"), st.get("lat"),
             [("ea_flood:stationReference", st.get("stationReference")), ("wiski", w), ("rloi", st.get("RLOIid") if isinstance(st.get("RLOIid"), str) else None)],
             S["ea_flood_monitoring"], "ENG", STATUS.get(str(st.get("status", "")).rsplit("/", 1)[-1].lower(), "unknown"), st.get("dateOpened"), None, st.get("riverName"),
             attrs={"catchment_name": st.get("catchmentName"), "town": st.get("town"), "grid_ref": st.get("gridReference")})
    # ── EA hydrology stations (resolve onto flood sites via stationReference / wiski / rloi / nrfa)
    for st in L("ea_hydrology/stations.json")["items"]:
        params = {m.get("parameter") for m in st.get("measures", [])}
        kind = "groundwater_station" if "groundwaterLevel" in params or st.get("aquifer") else ("rain_gauge" if params <= {"rainfall"} and params else "river_gauge")
        stat = st.get("status"); stat = stat[0].get("label", "").lower() if isinstance(stat, list) and stat else ""
        w = st.get("wiskiID"); w = w if isinstance(w, str) else None
        site(kind, st.get("label"), st.get("long"), st.get("lat"),
             [("ea_hydro:guid", st.get("stationGuid")), ("ea_flood:stationReference", st.get("stationReference")), ("wiski", w),
              ("rloi", st.get("RLOIid") if isinstance(st.get("RLOIid"), str) else None), ("nrfa:id", st.get("nrfaStationID"))],
             S["ea_hydrology"], "ENG", {"active": "active", "closed": "closed", "suspended": "suspended"}.get(stat, "unknown"), st.get("dateOpened"), st.get("dateClosed"), st.get("riverName"),
             attrs={"catchment_area_km2": st.get("catchmentArea"), "aquifer": st.get("aquifer")})
    # ── NRFA (resolves onto hydrology via nrfa:id; carries cross-authority ids)
    CTRY = {"SEPA": "SCT", "NRW": "WLS", "DfIR": "NIR"}
    nrfa = L("nrfa/station_info.json")["data"]
    for st in nrfa:
        auth = st.get("measuring-authority-id") or ""; a_id = st.get("measuring-authority-station-id")
        ids = [("nrfa:id", st["id"])]
        if auth.startswith("SEPA"): ids.append(("sepa:station_no", a_id))
        elif auth.startswith("NRW"): ids.append(("nrw:station_no", a_id))
        elif auth.startswith("DfIR"): ids.append(("dfi:station_no", a_id))
        site("river_gauge", st.get("name"), st.get("longitude"), st.get("latitude"), ids, S["nrfa"], CTRY.get(auth[:4].rstrip("-") if auth.startswith("DfIR") else auth.split("-")[0], "ENG" if auth.startswith("EA") else None),
             "unknown", None, None, None, attrs={"nrfa_authority": auth, "nrfa_authority_station": a_id})
    # ── SEPA stations
    sh = L("sepa/stations.json"); hdr = sh[0]
    for row in sh[1:]:
        r = dict(zip(hdr, row))
        try: lat, lon = float(r["station_latitude"]), float(r["station_longitude"])
        except Exception: continue
        site("river_gauge" if r.get("parametertype_name") != "Precip" else "rain_gauge", r["station_name"], lon, lat, [("sepa:station_no", r["station_no"])], S["sepa_kiwis"], "SCT", "unknown", None, None, r.get("river_name") or None,
             attrs={"sepa_catchment": r.get("catchment_name"), "sepa_parametertype": r.get("parametertype_name")})
    print("stations resolved:", dict(stats), round(time.time() - t0, 1), "s")

    # ── EA WQ sampling points (66k)
    pts = L("ea_wq/sampling_points.geojson")["features"]
    KIND = lambda t: ("sewage_works" if t.startswith("SEWAGE DISCHARGES - FINAL/TREATED EFFLUENT - WATER COMPANY") else
                      "consented_discharge" if t.startswith(("SEWAGE", "TRADE", "MISCELLANEOUS DISCHARGES")) else "wq_sampling_point")
    for f in pts:
        p = f["properties"]; c = f["geometry"]["coordinates"]; t = p.get("type") or ""
        site(KIND(t), p.get("name"), c[0], c[1], [("ea_wims:notation", p["notation"])], S["ea_wq_archive"], "ENG", {"OPEN": "active", "CLOSED": "closed"}.get(p.get("status"), "unknown"),
             attrs={"wq_type": t, "region": p.get("region"), "area": p.get("area")})
    print("with WQ points:", len(sites), round(time.time() - t0, 1), "s")

    # ── Storm overflows: EA annual returns give the registry + history; live feeds attach status
    ea = L("sewage/ea_edm_annual_returns_all_years.geojson")["features"]
    ea.sort(key=lambda f: f["properties"].get("annual_return_year") or "")
    def num(x):
        try:
            if x is None or str(x).strip() in ("", "#N/A", "N/A", "-", "NaN"): return None
            return float(str(x).replace(",", ""))
        except Exception: return None
    def composite(p):
        c = (p.get("water_company_name") or "").lower(); out = []
        pr = p.get("permit_reference_ea_condat"); ac = p.get("activity_reference_on_permit")
        if pr and pr not in ("Not in Consents Database", "No", "#N/A") and ac not in (None, ""): out.append(("edm:permit_activity", f"{c}|{pr}|{ac}"))
        wp = p.get("wasc_supplementary_permit_ref_opt")
        if wp and wp not in ("#N/A", "No"): out.append(("edm:wasc_permit", f"{c}|{wp}"))
        nm = p.get("site_name_wasc_op_name")
        if nm and not out: out.append(("edm:name", f"{c}|{nm.strip().lower()}"))
        return out
    LK = {}
    for r in L("sewage/id_lookup.json"):
        q = r.get("properties") or r.get("attributes") or r
        if q.get("Old_Unique_ID") and q.get("New_Unique_ID"): LK[q["Old_Unique_ID"]] = q["New_Unique_ID"]
    annual = {}          # (uid, year) -> dict
    overflow_attr = {}   # site_id -> dict
    for f in ea:
        p = f["properties"]; uid = p.get("unique_id") or p.get("old_unique_id_pre_2024")
        if not uid: continue
        g = f["geometry"]["coordinates"] if f.get("geometry") else None
        comp = ORG.get((p.get("water_company_name") or "").lower())
        sid = site("storm_overflow", p.get("site_name_wasc_op_name") or p.get("site_name_ea_condat"), g[0] if g else None, g[1] if g else None,
                   [("nsoh:id", uid)] + ([("nsoh:id", p["old_unique_id_pre_2024"])] if p.get("old_unique_id_pre_2024") else []) + ([("nsoh:id", p["unique_id"])] if p.get("unique_id") else []) + ([("nsoh:id", LK[p["old_unique_id_pre_2024"]])] if p.get("old_unique_id_pre_2024") in LK else []) + composite(p), S["ea_edm_annual"], "ENG", "unknown", None, None, p.get("receiving_water_environment_common_name_ea_condat"), comp,
                   attrs={"asset_type": p.get("storm_discharge_asset_type")})
        if sid is None: continue
        overflow_attr[sid] = dict(company=comp, permit=p.get("permit_reference_ea_condat"), asset=p.get("storm_discharge_asset_type"), recv=p.get("receiving_water_environment_common_name_ea_condat"),
                                  wb=p.get("wfd_waterbody_id"), bathing=p.get("bathing_water"), shellfish=p.get("shellfish_water"), legacy=[p["old_unique_id_pre_2024"]] if p.get("old_unique_id_pre_2024") else [])
        yr = int(p["annual_return_year"]) if (p.get("annual_return_year") or "").isdigit() else None
        if yr:
            annual[(sid, yr)] = dict(spills=num(p.get("counted_spills_12_24hr_calculated")) if p.get("counted_spills_12_24hr_calculated") is not None else num(p.get("counted_spills_12_24hr")),
                                     hours=num(p.get("total_spill_duration_hrs_calculated")) if p.get("total_spill_duration_hrs_calculated") is not None else num(p.get("total_duration_hrs_12_24hr")),
                                     opct=num(p.get("edm_operation_percent_calculated")) if p.get("edm_operation_percent_calculated") is not None else num(p.get("edm_operation_percent_of_reporting_period_edm_operational")),
                                     lt=num(p.get("longterm_average_spill_count_calculated")) if p.get("longterm_average_spill_count_calculated") is not None else num(p.get("longterm_average_spill_count")),
                                     has=bool(p.get("has_data")), q={k: p.get(k) for k in ("edm_operation_reporting_percent_primary_reason_less_than_90_perc", "high_spill_frequency_operational_review_primary_reason", "investigation_activity_for_the_reporting_period", "improvement_activity_for_the_reporting_period", "uwwtr_soaf_investigation_status", "counted_spills_12_24hr", "total_duration_hrs_12_24hr", "data_source") if p.get(k) not in (None, "")})
    print("overflows from annual:", len(overflow_attr), "annual rows", len(annual), round(time.time() - t0, 1), "s")
    # legacy ids -> overflow.legacy_ids
    for old, newid in LK.items():
        hit = ident.get(("nsoh:id", newid))
        if hit and hit[0] in overflow_attr and old not in overflow_attr[hit[0]]["legacy"]: overflow_attr[hit[0]]["legacy"].append(old)
    # live feeds
    live = {}   # site_id -> status dict
    def put_live(sid, status, raw, since, st, en, rep, src):
        live[sid] = dict(status=status, raw=raw, since=since or None, st=st or None, en=en or None, rep=rep or None, src=src)
    ms = lambda v: __import__("datetime").datetime.fromtimestamp(v / 1000, __import__("datetime").timezone.utc).isoformat() if isinstance(v, (int, float)) else None
    MAP = {1: "discharging", 0: "not_discharging", -1: "offline"}
    for fpath in sorted(glob.glob(os.path.join(RAW, "sewage", "nsoh", "*.geojson"))):
        base = os.path.basename(fpath); feats = json.load(open(fpath))["features"]
        if base.startswith("scottish_water_sepa_live"): continue    # same assets as the Stream-schema Scottish feed
        scot = base.startswith("scottish_water_stream")
        for f in feats:
            p = f["properties"]; g = f.get("geometry", {}).get("coordinates") if f.get("geometry") else None
            if scot:
                uid = p.get("ASSET_ID"); lon, lat = (g[0], g[1]) if g else (p.get("DISCHARGE_LOCATION_LONGITUDE"), p.get("DISCHARGE_LOCATION_LATITUDE"))
                sid = site("storm_overflow", p.get("ASSET_NAME"), lon, lat, [("nsoh:id", uid), ("sepa:cas", p.get("LICENCE_NUMBER"))], S["nsoh_scotland"], "SCT", "unknown", None, None, p.get("RECEIVING_WATER"), ORG["scottish water"], attrs={"overflow_type": p.get("OVERFLOW_TYPE")})
                if sid is None: continue
                overflow_attr.setdefault(sid, dict(company=ORG["scottish water"], permit=p.get("LICENCE_NUMBER"), asset=p.get("OVERFLOW_TYPE"), recv=p.get("RECEIVING_WATER"), wb=None, bathing=None, shellfish=None, legacy=[]))
                raw = p.get("STATUS_NSOH")
                put_live(sid, MAP.get(raw, "unknown"), str(raw), None, None, None, p.get("LAST_TRANSMITTED_DATETIME"), S["nsoh_scotland"])
            else:
                uid = p.get("Id") or p.get("id"); g2 = g or [p.get("Longitude") or p.get("longitude"), p.get("Latitude") or p.get("latitude")]
                gl = lambda k: p.get(k) if k in p else p.get(k[0].lower() + k[1:])
                comp = ORG.get((gl("Company") or "").lower())
                sid = site("storm_overflow", None, g2[0], g2[1], [("nsoh:id", uid)], S["nsoh_england"], "ENG", "unknown", None, None, gl("ReceivingWaterCourse"), comp)
                if sid is None: continue
                overflow_attr.setdefault(sid, dict(company=comp, permit=None, asset=None, recv=gl("ReceivingWaterCourse"), wb=None, bathing=None, shellfish=None, legacy=[]))
                raw = gl("Status")
                put_live(sid, MAP.get(raw, "unknown"), str(raw), ms(gl("StatusStart")), ms(gl("LatestEventStart")), ms(gl("LatestEventEnd")), ms(gl("LastUpdated")), S["nsoh_england"])
    print("overflow sites total:", len(overflow_attr), "live statuses:", len(live), round(time.time() - t0, 1), "s")

    # ── Bathing waters
    bath = L("bathing/sites_full.json"); bath_site = {}
    for b in bath:
        sp = b.get("samplingPoint") or {}; nm = (b.get("name") or {}).get("_value")
        t = {x.rsplit("/", 1)[-1] for x in (b.get("type") or [])}
        sid = site("bathing_water", nm, sp.get("long"), sp.get("lat"), [("eubwid", b.get("eubwidNotation"))], S["ea_bathing"], "ENG", "active",
                   attrs={"water_type": ",".join(sorted(t - {"BathingWater"})), "year_designated": str(b.get("yearDesignated", "")).rsplit("/", 1)[-1],
                          "district": next((d["name"]["_value"] for d in (b.get("district") or []) if isinstance(d, dict) and isinstance(d.get("name"), dict)), None),
                          "sewerage_undertaker": (b.get("appointedSewerageUndertaker") or {}).get("name", {}).get("_value")})
        if sid: bath_site[b.get("eubwidNotation")] = (sid, b)
    # ── Consented discharges (CaSTCo / EA permits)
    permits = []
    for f in json.load(open(os.path.join(RAW, "castco", "consented_sewage_discharges__0.geojson")))["features"]:
        p = f["properties"]; g = f["geometry"]["coordinates"] if f.get("geometry") else None
        if not g: continue
        kind = "sewage_works" if (p.get("DISCHARGE_SITE_TYPE_CODE") or "").startswith("A") else "consented_discharge"
        sid = site(kind, p.get("DISCHARGE_SITE_NAME"), g[0], g[1], [("permit", f"{p.get('PERMIT_NUMBER')}:{p.get('DISCHARGE_NGR')}")], S["castco_pressures"], "ENG", "active",
                   river=p.get("RECEIVING_WATER"), operator=ORG.get((p.get("COMPANY_NAME") or "").lower()), attrs={"permit_type": p.get("DSI_TYPE_DESCRIPTION"), "catchment_code": p.get("CATCHMENT_CODE")})
        if sid: permits.append((sid, p))
    print("total sites", len(sites), dict(stats), round(time.time() - t0, 1), "s")

    # ══ WRITE
    cur.execute("create temp table stg_site (id bigint, kind text, name text, lon double precision, lat double precision, country text, status text, opened text, closed text, river text, operator bigint, src bigint, attrs text) on commit drop")
    def yd(x): return x if isinstance(x, str) and re.match(r"^\d{4}-\d{2}-\d{2}", x) else None
    copy_rows(cur, "stg_site", ["id", "kind", "name", "lon", "lat", "country", "status", "opened", "closed", "river", "operator", "src", "attrs"],
              ((i, d["kind"], d["name"], d["lon"], d["lat"], d["country"], d["status"], yd(d["opened"]), yd(d["closed"]), d["river"], d["operator"], d["src"], jdump({k: v for k, v in d["attrs"].items() if v is not None})) for i, d in sites.items()))
    cur.execute("""insert into core.site (id, kind, name, geom, geom_bng, country, operator_id, status, opened_on, closed_on, river_name_raw, primary_source_id, attrs)
        overriding system value
        select id, kind, name, ST_SetSRID(ST_MakePoint(lon, lat), 4326),
               case when lon between -9 and 2.5 and lat between 49.5 and 61 then ST_Transform(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 27700) end,
               country, operator, status, opened::date, closed::date, river, src, attrs::jsonb
        from stg_site where lon between -11 and 3 and lat between 49 and 61.5""")
    cur.execute("create temp table stg_id (scheme text, value text, site_id bigint, src bigint, method text, conf real) on commit drop")
    copy_rows(cur, "stg_id", ["scheme", "value", "site_id", "src", "method", "conf"], ((a, b, v[0], v[1], v[2], v[3]) for (a, b), v in ident.items() if v[0] in sites))
    cur.execute("insert into core.site_identifier (scheme, value, site_id, source_id, match_method, confidence) select s.scheme, s.value, s.site_id, s.src, s.method, s.conf from stg_id s join core.site c on c.id = s.site_id on conflict do nothing")
    # overflow table
    cur.execute("create temp table stg_ov (site_id bigint, company bigint, permit text, asset text, recv text, wb text, bathing text, shellfish text, legacy text[]) on commit drop")
    copy_rows(cur, "stg_ov", ["site_id", "company", "permit", "asset", "recv", "wb", "bathing", "shellfish", "legacy"],
              ((i, o["company"], o["permit"], o["asset"], o["recv"], o["wb"], o["bathing"], o["shellfish"], o["legacy"]) for i, o in overflow_attr.items()))
    cur.execute("""insert into core.overflow (site_id, company_id, permit_ref, asset_type, receiving_water_raw, receiving_waterbody_id, legacy_ids, is_shellfish_water)
        select s.site_id, s.company, s.permit, s.asset, s.recv, w.id, s.legacy, case when s.shellfish is null then null else lower(s.shellfish) in ('y','yes','true','1') end
        from stg_ov s join core.site c on c.id = s.site_id left join core.waterbody w on w.wb_code = s.wb on conflict do nothing""")
    cur.execute("create temp table stg_live (site_id bigint, status text, raw text, since text, st text, en text, rep text, src bigint) on commit drop")
    copy_rows(cur, "stg_live", ["site_id", "status", "raw", "since", "st", "en", "rep", "src"], ((i, v["status"], v["raw"], v["since"], v["st"], v["en"], v["rep"], v["src"]) for i, v in live.items()))
    cur.execute("""insert into core.overflow_status (site_id, status, raw_status, status_since, last_event_start, last_event_end, reported_at, fetched_at, source_id)
        select s.site_id, s.status, s.raw, s.since::timestamptz, s.st::timestamptz, s.en::timestamptz, s.rep::timestamptz, now(), s.src from stg_live s join core.site c on c.id = s.site_id on conflict do nothing""")
    cur.execute("create temp table stg_an (site_id bigint, year smallint, spills numeric, hours numeric, opct numeric, lt numeric, has boolean, q text, src bigint) on commit drop")
    copy_rows(cur, "stg_an", ["site_id", "year", "spills", "hours", "opct", "lt", "has", "q", "src"], ((k[0], k[1], v["spills"], v["hours"], v["opct"], v["lt"], v["has"], jdump(v["q"]), S["ea_edm_annual"]) for k, v in annual.items()))
    cur.execute("""insert into core.discharge_annual (site_id, year, source_id, spill_count, total_duration_hr, edm_operating_pct, longterm_avg_spills, has_data, qualifiers)
        select s.site_id, s.year, s.src, s.spills::int, s.hours, s.opct, s.lt, s.has, s.q::jsonb from stg_an s join core.site c on c.id = s.site_id on conflict do nothing""")
    # bathing: assessments
    cur.execute("create temp table stg_bw (site_id bigint, year smallint, cls text, src bigint) on commit drop")
    rows = []
    for k, (sid, b) in bath_site.items():
        ca = b.get("latestComplianceAssessment") or {}
        about = ca.get("_about", ""); m = re.search(r"/year/(\d{4})", about); cn = ((ca.get("complianceClassification") or {}).get("name") or {}).get("_value")
        if m and cn: rows.append((sid, int(m.group(1)), cn.lower(), S["ea_bathing"]))
    copy_rows(cur, "stg_bw", ["site_id", "year", "cls", "src"], rows)
    cur.execute("insert into core.bathing_assessment (site_id, year, classification, rank, source_id) select s.site_id, s.year, case when s.cls in ('excellent','good','sufficient','poor') then s.cls else 'not_classified' end, case s.cls when 'excellent' then 1 when 'good' then 2 when 'sufficient' then 3 when 'poor' then 4 end, s.src from stg_bw s join core.site c on c.id=s.site_id on conflict do nothing")
    # permits
    cur.execute("create temp table stg_pm (site_id bigint, ref text, ver int, holder bigint, dtype text, renv text, rwater text, status text, issued text, eff text, rev text, src bigint) on commit drop")
    ep = lambda x: __import__("datetime").datetime.fromtimestamp(x / 1000, __import__("datetime").timezone.utc).date().isoformat() if isinstance(x, (int, float)) else None
    copy_rows(cur, "stg_pm", ["site_id", "ref", "ver", "holder", "dtype", "renv", "rwater", "status", "issued", "eff", "rev", "src"],
              ((sid, p.get("PERMIT_NUMBER"), p.get("PERMIT_VERSION"), ORG.get((p.get("COMPANY_NAME") or "").lower()), p.get("DSI_TYPE_DESCRIPTION"), p.get("REC_ENV_CODE_DESCRIPTION"), p.get("RECEIVING_WATER"), p.get("STATUS_OF_PERMIT"), ep(p.get("ISSUED_DATE")), ep(p.get("EFFECTIVE_DATE")), ep(p.get("REVOCATION_DATE")), S["castco_pressures"]) for sid, p in permits if p.get("PERMIT_NUMBER")))
    cur.execute("""insert into core.permit (permit_ref, version, site_id, holder_id, discharge_type, receiving_environment, receiving_water_raw, status, issued_on, effective_on, revoked_on, source_id)
        select s.ref, s.ver, s.site_id, s.holder, s.dtype, s.renv, s.rwater, s.status, s.issued::date, eff::date, rev::date, src from stg_pm s join core.site c on c.id = s.site_id on conflict do nothing""")
    # NRFA attributes
    cur.execute("create temp table stg_at (site_id bigint, key text, num double precision, txt text, src bigint) on commit drop")
    rows = []
    KEEP = ("catchment-area", "bfihost19", "farl", "propwet", "saar", "altbar", "urbext2000", "dpsbar", "draindens", "lcm2020-cropland", "lcm2020-grassland", "lcm2020-built-up-areas", "lcm2020-deciduous-woodland", "lcm2020-evergreen-woodland", "lcm2020-inland-water", "lcm2020-shrubland", "lcm2020-bare-soil-rock", "gdf-mean-flow", "gdf-q95-flow", "gdf-q50-flow", "gdf-q10-flow", "gdf-max-flow", "gdf-start-date", "gdf-end-date")
    for st in nrfa:
        sid = ident.get(("nrfa:id", str(st["id"])), (None,))[0]
        if sid not in sites: continue
        for k in KEEP:
            v = st.get(k)
            if v is None: continue
            if isinstance(v, (int, float)): rows.append((sid, k.replace("-", "_"), float(v), None, S["nrfa"]))
            else: rows.append((sid, k.replace("-", "_"), None, str(v), S["nrfa"]))
    copy_rows(cur, "stg_at", ["site_id", "key", "num", "txt", "src"], rows)
    cur.execute("insert into core.site_attribute (site_id, key, value_num, value_text, source_id) select site_id, key, num, txt, src from stg_at s where exists (select 1 from core.site c where c.id=s.site_id) on conflict do nothing")
    for tbl in ("site", "site_identifier", "overflow", "overflow_status", "discharge_annual", "bathing_assessment", "permit", "site_attribute"):
        cur.execute(f"select count(*) from core.{tbl}"); print(tbl, cur.fetchone()[0])
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
