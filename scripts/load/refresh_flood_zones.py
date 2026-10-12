"""Danger zones: EA flood zones 2 and 3, fetched by bounding box for places with an active flood risk, clipped to where the risk applies.
Triggers: an active flood alert or warning (clipped to the warned area), or a gauge reading high or severe (clipped to 3 km around its stretch)."""
import json, os, sys, time
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")]
import lib
from db import *
B = "https://environment.data.gov.uk/spatialdata/flood-map-for-planning-flood-zones/ogc/features/v1/collections/Flood_Zones_2_3_Rivers_and_Sea/items"
t0 = time.time()
def fetch(bb, cap=4000):
    out, off = [], 0
    while len(out) < cap:
        d = lib.getj(B, params={"bbox": ",".join(f"{v:.5f}" for v in bb), "limit": 1000, "offset": off, "f": "json"}, timeout=120)
        f = d.get("features", []); out += f
        if len(f) < 1000: break
        off += 1000
    return out
def cells(bb, step=0.25):
    x = bb[0]
    while x < bb[2]:
        y = bb[1]
        while y < bb[3]: yield (x, y, min(x + step, bb[2]), min(y + step, bb[3])); y += step
        x += step
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "ea_flood_zones"); cur.execute("truncate core.flood_zone")
    targets = []
    cur.execute("""select a.code, a.name, w.severity_level, ST_XMin(a.geom_active), ST_YMin(a.geom_active), ST_XMax(a.geom_active), ST_YMax(a.geom_active), ST_AsText(a.geom_active)
                   from core.flood_area a join lateral (select * from core.flood_warning w where w.area_id = a.id order by w.changed_at desc nulls last limit 1) w on w.severity_level < 4 where a.geom_active is not null""")
    for code, name, sv, x0, y0, x1, y1, wkt in cur.fetchall():
        targets.append(("warning", code, f"{({1: 'Severe flood warning', 2: 'Flood warning', 3: 'Flood alert'}).get(sv, 'Flood alert')}: {name}", (x0, y0, x1, y1), wkt))
    cur.execute("""select s.id, s.name, g.band, coalesce(ST_XMin(w.line_geom), ST_X(s.geom) - .05), coalesce(ST_YMin(w.line_geom), ST_Y(s.geom) - .05), coalesce(ST_XMax(w.line_geom), ST_X(s.geom) + .05), coalesce(ST_YMax(w.line_geom), ST_Y(s.geom) + .05),
                          ST_AsText(ST_Buffer(coalesce(w.line_geom, s.geom), 0.03))
                   from core.gauge_state g join core.site s on s.id = g.site_id left join core.waterbody w on w.id = s.waterbody_id where g.band_rank >= 4 and s.geom is not null and ST_X(s.geom) between -6.5 and 2""")
    for sid, name, band, x0, y0, x1, y1, wkt in cur.fetchall():
        targets.append(("gauge", str(sid), f"{name}: river {band}", (x0 - .03, y0 - .03, x1 + .03, y1 + .03), wkt))
    print("risk areas:", len(targets), [(t[0], t[2][:50]) for t in targets][:6])
    n = 0
    for trig, ref, reason, bb, wkt in targets:
        rows = []
        for c in cells(bb):
            for f in fetch(c): 
                z = (f["properties"].get("flood_zone") or "").upper()
                if z in ("FZ2", "FZ3") and f.get("geometry"): rows.append((z, json.dumps(f["geometry"])))
        if not rows: continue
        cur.execute("create temp table if not exists stg_z (zone text, g text, wkt text) on commit drop"); cur.execute("truncate stg_z")
        copy_rows(cur, "stg_z", ["zone", "g", "wkt"], ((z, g, wkt) for z, g in rows))
        cur.execute("""insert into core.flood_zone (zone, geom, trigger, reason, ref, source_id)
            select zone, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_Intersection(ST_MakeValid(zg), ST_GeomFromText(%s, 4326))), 3)), %s, %s, %s, %s
            from (select zone, ST_SetSRID(ST_GeomFromGeoJSON(g), 4326) zg from stg_z) q
            where ST_Intersects(ST_MakeValid(zg), ST_GeomFromText(%s, 4326))""", (wkt, trig, reason, ref, src, wkt)); n += len(rows)
        cur.execute("delete from core.flood_zone where ST_IsEmpty(geom)")
    cur.execute("select trigger, zone, count(*), round((sum(ST_Area(ST_Transform(geom, 27700))) / 1e6)::numeric, 1) from core.flood_zone group by 1, 2 order by 1, 2"); print("flood zone polygons (trigger, zone, n, km2):", cur.fetchall())
    cur.execute("analyze core.flood_zone"); conn.commit()
print("done", round(time.time() - t0, 1), "s")
