"""OS Open Rivers GeoPackage -> core.river_node, geo.river_link (BNG kept, WGS84 derived in PostGIS)."""
import sqlite3, struct, time, os
from db import *

GPKG = os.path.join(RAW, "osrivers", "Data", "oprvrs_gb.gpkg")

def wkb_of(blob):
    # GeoPackage binary header: 'GP', version, flags, srs_id(4), [envelope]
    flags = blob[3]; env = (flags >> 1) & 7
    env_len = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}[env]
    return bytes(blob[8 + env_len:])

t0 = time.time()
src = sqlite3.connect(GPKG)
with connect() as conn, conn.cursor() as cur:
    run = start_run(cur, "os_open_rivers", "load_network.py")
    cur.execute("create temp table stg_node (os_id text, category text, wkb bytea) on commit drop")
    cur.execute("create temp table stg_link (os_id text, form text, name text, name_alt text, length_m real, flow_direction text, start_os text, end_os text, wkb bytea) on commit drop")
    n = copy_rows(cur, "stg_node", ["os_id", "category", "wkb"],
                  ((i, c, wkb_of(g)) for g, i, c in src.execute("select geometry, id, hydro_node_category from hydro_node")))
    m = copy_rows(cur, "stg_link", ["os_id", "form", "name", "name_alt", "length_m", "flow_direction", "start_os", "end_os", "wkb"],
                  ((i, f, nm, na, ln, fd, s, e, wkb_of(g)) for g, i, fd, ln, f, nm, na, s, e in
                   src.execute("select geometry, id, flow_direction, length, form, watercourse_name, watercourse_name_alternative, start_node, end_node from watercourse_link")))
    print("staged", n, m, round(time.time() - t0, 1), "s")
    cur.execute("""insert into core.river_node (os_id, category, geom, geom_bng)
        select os_id, category, ST_Transform(g, 4326), g from (select os_id, category, ST_SetSRID(ST_GeomFromWKB(wkb), 27700) g from stg_node) q""")
    cur.execute("""insert into geo.river_link (os_id, form, name, name_alt, length_m, flow_direction, start_node_id, end_node_id, geom, geom_bng)
        select l.os_id, l.form, l.name, l.name_alt, l.length_m, l.flow_direction, s.id, e.id,
               ST_Transform(ST_Force2D(g), 4326), ST_Force2D(g)
        from (select *, ST_SetSRID(ST_GeomFromWKB(wkb), 27700) g from stg_link) l
        join core.river_node s on s.os_id = l.start_os
        join core.river_node e on e.os_id = l.end_os""")
    cur.execute("select count(*) from core.river_node"); a = cur.fetchone()[0]
    cur.execute("select count(*) from geo.river_link"); b = cur.fetchone()[0]
    finish_run(cur, run, read=n + m, written=a + b)
    conn.commit()
    print("loaded nodes", a, "links", b, round(time.time() - t0, 1), "s")
