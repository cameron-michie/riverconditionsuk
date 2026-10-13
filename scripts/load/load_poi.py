"""OSM named bridges, reservoirs and beaches -> core.poi. Bridges are kept only where they cross or run beside a real watercourse (<= 40 m)."""
import json, os, re, time
from db import *
t0 = time.time()
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "osm_poi")
    cur.execute("delete from core.poi where source_id = %s", (src,))
    cur.execute("create temp table stg_p (kind text, id text, name text, lon double precision, lat double precision, attrs text) on commit drop")
    rows = []
    for f in ("bridges",):
        p = os.path.join(RAW, "osm", f + ".json")
        if not os.path.exists(p): print("missing", f); continue
        for d in json.load(open(p)):
            if -11 < d["lon"] < 3 and 49 < d["lat"] < 61.5: rows.append((d["kind"], d["id"], d["name"].strip(), d["lon"], d["lat"], jdump(d.get("tags", {}))))
    copy_rows(cur, "stg_p", ["kind", "id", "name", "lon", "lat", "attrs"], rows)
    cur.execute("""insert into core.poi (kind, name, geom, geom_bng, source_id, source_key, attrs)
        select kind, name, ST_SetSRID(ST_MakePoint(lon, lat), 4326), ST_Transform(ST_SetSRID(ST_MakePoint(lon, lat), 4326), 27700), %s, id, attrs::jsonb from stg_p on conflict do nothing""", (src,))
    cur.execute("analyze core.poi")
    # snap to the network
    cur.execute("""with k as (
        select p.id pid, p.kind, n.river_id, n.waterbody_id, ST_Distance(p.geom_bng, n.geom_bng) d
        from core.poi p cross join lateral (select river_id, waterbody_id, geom_bng from geo.river_link where size_class >= case when p.kind = 'bridge' then 2 else 0 end order by geom_bng <-> p.geom_bng limit 1) n
        where p.source_id = %s and p.kind in ('bridge', 'reservoir'))
        update core.poi p set river_id = case when k.d <= case k.kind when 'bridge' then 40 else 600 end then k.river_id end,
                              waterbody_id = case when k.d <= case k.kind when 'bridge' then 40 else 600 end then k.waterbody_id end, snap_distance_m = k.d
        from k where k.pid = p.id""", (src,))
    cur.execute("select count(*) from core.poi where kind = 'bridge'"); before = cur.fetchone()[0]
    cur.execute("delete from core.poi where source_id = %s and kind = 'bridge' and (snap_distance_m is null or snap_distance_m > 40)", (src,))
    cur.execute("select count(*) from core.poi where kind = 'bridge'"); print("bridges kept", cur.fetchone()[0], "of", before)
    cur.execute("select kind, count(*), count(river_id) with_river from core.poi group by 1 order by 1"); print(cur.fetchall())
    cur.execute("analyze core.poi"); conn.commit()
print("done", round(time.time() - t0, 1), "s")

# ── natural water as polygons -> core.water_area
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "osm_poi"); cur.execute("delete from core.water_area where source_id = %s", (src,))
    cur.execute("create temp table stg_r (key text, name text, kind text, g text, attrs text) on commit drop")
    rows = []
    for d in json.load(open(os.path.join(RAW, "osm", "water.json"))):
        if d.get("poly"): rows.append((d["id"], (d.get("name") or "").strip() or None, d["kind"], json.dumps({"type": "MultiPolygon", "coordinates": d["poly"]}), jdump(d.get("tags", {}))))
    copy_rows(cur, "stg_r", ["key", "name", "kind", "g", "attrs"], rows)
    cur.execute("""insert into core.water_area (name, kind, geom, label_pt, area_km2, source_id, source_key, attrs)
        select name, kind, geom, ST_PointOnSurface(geom), ST_Area(ST_Transform(geom, 27700)) / 1e6, %s, key, attrs::jsonb from (
          select s.*, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)), 3)) geom from stg_r s) q
        where not ST_IsEmpty(geom) on conflict do nothing""", (src,))
    cur.execute("analyze core.water_area"); cur.execute("select kind, count(*), round(sum(area_km2)::numeric), round(max(area_km2)::numeric,1) from core.water_area group by 1 order by 2 desc"); print("water (kind, n, km2, max km2):", cur.fetchall())
    conn.commit()

# ── beaches as polygons -> core.beach_area (linked to a designated bathing water within 800 m)
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "osm_poi"); cur.execute("delete from core.beach_area where source_id = %s", (src,))
    cur.execute("create temp table stg_b (key text, name text, g text, attrs text) on commit drop")
    rows = []
    for d in json.load(open(os.path.join(RAW, "osm", "beaches.json"))):
        if d.get("poly"): rows.append((d["id"], (d.get("name") or "").strip() or None, json.dumps({"type": "MultiPolygon", "coordinates": d["poly"]}), jdump(d.get("tags", {}))))
    copy_rows(cur, "stg_b", ["key", "name", "g", "attrs"], rows)
    cur.execute("""insert into core.beach_area (name, geom, label_pt, area_km2, source_id, source_key, attrs)
        select name, geom, ST_PointOnSurface(geom), ST_Area(ST_Transform(geom, 27700)) / 1e6, %s, key, attrs::jsonb from (
          select s.*, ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(g), 4326)), 3)) geom from stg_b s) q
        where not ST_IsEmpty(geom) on conflict do nothing""", (src,))
    cur.execute("""update core.beach_area b set bathing_site_id = x.sid from (
        select b2.id bid, (select s.id from geo.site s where s.kind = 'bathing_water' and s.geom_bng is not null order by s.geom_bng <-> ST_Transform(b2.label_pt, 27700) limit 1) sid from core.beach_area b2) x
        where x.bid = b.id and ST_Distance(ST_Transform(b.label_pt, 27700), (select geom_bng from geo.site where id = x.sid)) <= 800""")
    cur.execute("analyze core.beach_area"); cur.execute("select count(*), count(name), count(bathing_site_id), round(sum(area_km2)::numeric, 1) from core.beach_area"); print("beach areas (n, named, bathing-linked, km2):", cur.fetchone())
    conn.commit()

# ── massive bridges as outlines -> core.bridge_area.
# Rule: a bridge-like name; a way >= 700 m; not under construction or proposed; and >= 20% of its length over water, where water means
# outside the land outline (estuaries, firths), or within 60 m of a major river / tidal reach, or over a large water body.
with connect() as conn, conn.cursor() as cur:
    src = source_id(cur, "osm_poi"); cur.execute("delete from core.bridge_area where source_id = %s", (src,))
    cur.execute("create temp table stg_br (key text, name text, len int, line text) on commit drop")
    rows = []
    bad = {"construction", "proposed", "subway", "monorail", "abandoned", "disused"}
    for d in json.load(open(os.path.join(RAW, "osm", "bridges.json"))):
        tg = d.get("tags", {})
        if not d.get("line") or d["len_m"] < 700: continue
        if tg.get("highway") in bad or tg.get("railway") in bad: continue
        if not (re.search(r"bridge|viaduct|crossing|causeway|aqueduct", d["name"], re.I) or tg.get("man_made") == "bridge"): continue
        if re.search(r"cycleway|cycle|footway|walkway|HS2|High Speed 2", d["name"], re.I): continue
        rows.append((d["id"], d["name"], d["len_m"], json.dumps({"type": "LineString", "coordinates": d["line"]})))
    copy_rows(cur, "stg_br", ["key", "name", "len", "line"], rows)
    cur.execute("create temp table land on commit drop as select ST_Union(ST_Transform(geom_mid, 27700)) g from core.boundary where kind = 'country'")
    cur.execute("create temp table cand on commit drop as select key, name, len, ST_Transform(ST_SetSRID(ST_GeomFromGeoJSON(line), 4326), 27700) g from stg_br")
    cur.execute("create index on cand using gist (g)")
    cur.execute("""create temp table cand2 on commit drop as
        select c.*, greatest(
           (select ST_Length(ST_Difference(c.g, land.g)) from land) / nullif(ST_Length(c.g), 0),
           coalesce((select ST_Length(ST_Intersection(c.g, ST_Buffer(ST_Collect(l.geom_bng), 60))) from geo.river_link l where l.size_class >= 7 and l.geom_bng && ST_Expand(c.g, 80) and ST_DWithin(l.geom_bng, c.g, 60)), 0) / nullif(ST_Length(c.g), 0),
           coalesce((select ST_Length(ST_Intersection(c.g, ST_Buffer(ST_Collect(ST_Transform(w.geom, 27700)), 20))) from core.water_area w where w.area_km2 >= 1 and w.geom && ST_Transform(ST_Expand(c.g, 80), 4326) and ST_DWithin(ST_Transform(w.geom, 27700), c.g, 20)), 0) / nullif(ST_Length(c.g), 0)
        ) as over_water from cand c""")
    cur.execute("create temp table grp on commit drop as select *, ST_ClusterDBSCAN(g, 400, 1) over (partition by name) cl from cand2 where over_water >= 0.2")
    cur.execute("""insert into core.bridge_area (name, geom, length_m, source_id, source_keys)
        select name, ST_Transform(ST_Multi(ST_CollectionExtract(ST_Union(ST_Buffer(g, 14, 'endcap=flat')), 3)), 4326), max(len), %s, array_agg(key) from grp group by name, cl""", (src,))
    cur.execute("delete from core.poi p using core.bridge_area b where p.kind = 'bridge' and p.name = b.name and ST_DWithin(p.geom_bng, ST_Transform(b.geom, 27700), 800)")
    cur.execute("select name, length_m from core.bridge_area order by length_m desc"); rs = cur.fetchall(); print("bridge outlines:", len(rs)); print(rs)
    cur.execute("analyze core.bridge_area"); conn.commit()
