"""One-off (rerun when catchments change): list the radar cells inside every waterbody catchment -> geo.waterbody.radar_cells (ix * 10000 + iy)."""
import os, sys
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load"), os.path.dirname(os.path.abspath(__file__))]
import numpy as np
from shapely import wkb
from shapely.ops import transform
from skimage.draw import polygon as raster_polygon
from db import connect, copy_rows
import wxlib

def cells(geom):
    out = set()
    for poly in getattr(geom, "geoms", [geom]):
        xs, ys = poly.exterior.coords.xy
        ix, iy = wxlib.lonlat_to_cell(np.array(xs), np.array(ys))
        rr, cc = raster_polygon(iy, ix, wxlib.RADAR_SHAPE)
        out.update(zip(cc.tolist(), rr.tolist()))
    return out

with connect() as conn, conn.cursor() as cur:
    cur.execute("select id, ST_AsBinary(ST_Simplify(catchment_geom, 0.001)), ST_X(ST_PointOnSurface(catchment_geom)), ST_Y(ST_PointOnSurface(catchment_geom)) from geo.waterbody where catchment_geom is not null")
    rows, alone = [], 0
    for wid, g, lon, lat in cur.fetchall():
        c = cells(wkb.loads(bytes(g)))
        if not c:
            ix, iy = wxlib.lonlat_to_cell(lon, lat); c = {(int(ix), int(iy))}; alone += 1
        rows += [(wid, x, y) for x, y in c if 0 <= x < wxlib.RADAR_SHAPE[1] and 0 <= y < wxlib.RADAR_SHAPE[0]]
    cur.execute("create temp table stg_c (waterbody_id bigint, ix int, iy int) on commit drop"); n = copy_rows(cur, "stg_c", ["waterbody_id", "ix", "iy"], rows)
    cur.execute("update geo.waterbody set radar_cells = null")
    cur.execute("update geo.waterbody w set radar_cells = x.c from (select waterbody_id, array_agg(ix * 10000 + iy order by ix, iy) c from stg_c group by 1) x where x.waterbody_id = w.id")
    conn.commit(); print(n, "cells for", len({r[0] for r in rows}), "catchments;", alone, "smaller than a cell (centroid cell used)")
