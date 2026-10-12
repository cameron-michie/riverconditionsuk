"""Named bridges, reservoirs and beaches from the Geofabrik Great Britain extract (OpenStreetMap, ODbL). One pass, no Overpass."""
import json, os, sys, time
import osmium
from lib import *
S = "osm"
PBF = os.path.join(ROOT, "osm", "great-britain.osm.pbf")
BRIDGE_OK = {"yes", "viaduct", "aqueduct", "movable", "suspension", "cantilever", "arch", "beam", "truss", "trestle", "bascule", "swing", "lift", "boardwalk", "covered", "low_water_crossing"}
KEEP = ("bridge", "highway", "railway", "waterway", "man_made", "ref", "operator", "layer", "name:cy", "water", "landuse", "natural", "surface", "intermittent", "wikidata", "tourism", "access")
out = {"bridges": {}, "water": {}, "beaches": {}}
NOT_NATURAL = {"river", "stream", "canal", "ditch", "drain", "moat", "wastewater", "sewage", "lock", "fish_pass", "reflecting_pool", "swimming_pool", "pool", "basin_wastewater"}
def wkind(t):
    w = t.get("water", "")
    return "reservoir" if (w == "reservoir" or t.get("landuse") == "reservoir") else "lake" if w in ("lake", "loch", "lagoon", "oxbow", "lough", "tarn") else "pond" if w == "pond" else "other"
t0 = time.time(); n = 0
fp = (osmium.FileProcessor(PBF, osmium.osm.NODE | osmium.osm.WAY | osmium.osm.RELATION).with_locations().with_areas(osmium.filter.KeyFilter("natural", "landuse", "water"))
      .with_filter(osmium.filter.EntityFilter(osmium.osm.WAY | osmium.osm.AREA)))
for o in fp:
    n += 1
    if n % 5_000_000 == 0: log(S, f"{n/1e6:.0f}M objects {int(time.time()-t0)}s bridges={len(out['bridges'])} water={len(out['water'])} beaches={len(out['beaches'])}")
    t = o.tags
    if o.is_way():
        if "name" not in t: continue
        b = t.get("bridge")
        if b and b != "no" and (t.get("highway") or t.get("railway") or t.get("waterway") or t.get("man_made") == "bridge" or t.get("bridge:name")):
            ns = [(c.lon, c.lat) for c in o.nodes if c.location.valid()]
            if ns:
                lon, lat = ns[len(ns) // 2]
                row = dict(kind="bridge", name=t["name"], lat=lat, lon=lon, tags={k: t[k] for k in KEEP if k in t})
                import math
                ln = sum(math.hypot((q[0] - p[0]) * 111320 * math.cos(math.radians(p[1])), (q[1] - p[1]) * 110540) for p, q in zip(ns, ns[1:]))
                row["len_m"] = round(ln)
                if ln >= 300: row["line"] = ns                    # outlines only for long bridges; the rest stay points
                out["bridges"]["w%d" % o.id] = row
        continue
    if not o.is_area(): continue
    if t.get("natural") == "water" and t.get("water") not in NOT_NATURAL or t.get("water") == "reservoir" or t.get("landuse") == "reservoir": kind = "water"
    elif t.get("natural") == "beach": kind = "beaches"
    else: continue
    try:
        rings_all = []
        for r in o.outer_rings():
            rings_all.append([[(c.lon, c.lat) for c in r if c.location.valid()]] + [[(c.lon, c.lat) for c in ir if c.location.valid()] for ir in o.inner_rings(r)])
        pts = [p for poly in rings_all for p in poly[0]]
    except Exception: continue
    if not pts: continue
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    if kind == "water" and "name" not in t and max(max(xs) - min(xs), max(ys) - min(ys)) < 0.004: continue     # unnamed and under ~400 m across
    if kind == "beaches" and "name" not in t and max(max(xs) - min(xs), max(ys) - min(ys)) < 0.002: continue   # unnamed and under ~200 m across
    row = dict(name=t.get("name"), lat=sum(ys) / len(ys), lon=sum(xs) / len(xs), tags={k: t[k] for k in KEEP if k in t})
    if kind == "water": row.update(kind=wkind(t), poly=rings_all)
    else: row.update(kind="beach", poly=rings_all)
    out[kind]["a%d" % o.id] = row
for k, v in out.items():
    rows = [dict(id=i, **d) for i, d in v.items()]
    save(S, f"{k}.json", rows, "https://download.geofabrik.de/europe/great-britain-latest.osm.pbf", "ODbL (c) OpenStreetMap contributors"); log(S, f"{k}: {len(rows)}")
log(S, f"done in {int(time.time()-t0)}s")
