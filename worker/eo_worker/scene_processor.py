"""Process one Sentinel-2 scene: windowed COG reads under each observable reach, run detectors, store rows."""
from __future__ import annotations

import json
import logging

import numpy as np

from . import config
from .detectors import chlorophyll as chl

log = logging.getLogger("eo.scene")


def _load_calibration(cur) -> dict | None:
    cur.execute("select coefficients from core.eo_calibration where detector='chlorophyll' and optical_class='all' and is_current")
    r = cur.fetchone()
    return r[0] if r else None


def process_scene(conn, scene_id: int) -> int:
    import rasterio
    from rasterio.features import geometry_mask
    from rasterio.warp import transform_geom
    from rasterio.windows import from_bounds
    from shapely.geometry import shape
    from shapely.ops import transform as shp_transform  # noqa: F401  (kept for detector plugins)

    with conn.cursor() as cur:
        cur.execute("select assets, acquired_at::date, st_asgeojson(bbox) from core.scene where id=%s", (scene_id,))
        assets, day, _ = cur.fetchone()
        coef = _load_calibration(cur)
        # observable reaches inside the scene and not yet scored for it
        cur.execute(
            """select r.id, st_asgeojson(r.geom), coalesce(r.width_m, 30)
               from core.reach r join core.scene s on st_intersects(s.bbox, r.geom)
               where s.id=%s and r.observable_s2
                 and not exists (select 1 from core.eo_observation o
                                 where o.reach_id=r.id and o.scene_id=s.id and o.detector='chlorophyll'
                                   and o.algo_version=%s and o.observed_on=%s)""",
            (scene_id, chl.ALGO_VERSION, day),
        )
        reaches = cur.fetchall()
    if not reaches:
        return 0

    written = 0
    env = rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", AWS_NO_SIGN_REQUEST="YES",
                       GDAL_HTTP_MULTIPLEX="YES", CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif")
    with env:
        srcs = {k: rasterio.open(assets[k]) for k in config.BANDS}
        try:
            ref = srcs["b4"]
            for rid, geojson, width in reaches:
                g = transform_geom("EPSG:4326", ref.crs, json.loads(geojson))
                poly = shape(g).buffer(max(width / 2 + 10, 15))      # centreline -> channel + 1 pixel slack
                try:
                    win = from_bounds(*poly.bounds, transform=ref.transform).round_offsets().round_lengths()
                    if win.width < 2 or win.height < 2:
                        continue
                    shape_px = (int(win.height), int(win.width))
                    arrs = {}
                    for k, src in srcs.items():
                        # B5 and SCL are 20 m: each band needs a window from its OWN transform, resampled
                        # onto the 10 m reference grid (nearest for SCL classes, bilinear for reflectance)
                        bwin = from_bounds(*poly.bounds, transform=src.transform)
                        arrs[k] = src.read(1, window=bwin, out_shape=shape_px, boundless=True, fill_value=0,
                                           resampling=rasterio.enums.Resampling.nearest if k == "scl"
                                           else rasterio.enums.Resampling.bilinear)
                    # Earth Search C1 L2A: reflectance = DN * 0.0001 - 0.1 (DN 0 = nodata)
                    refl = {k: np.where(arrs[k] == 0, np.nan, arrs[k].astype("float32") * 1e-4 - 0.1)
                            for k in ("b3", "b4", "b5", "b8")}
                    tr = rasterio.windows.transform(win, ref.transform)
                    mask = ~geometry_mask([poly], out_shape=shape_px, transform=tr)
                    m = chl.reach_metrics(refl["b3"], refl["b4"], refl["b5"], refl["b8"], arrs["scl"], mask, coef)
                except Exception:           # one bad reach must not sink the scene
                    log.exception("reach %s failed", rid)
                    continue
                if not m:
                    continue
                with conn.cursor() as cur:
                    cur.execute(
                        """insert into core.eo_observation
                             (reach_id, scene_id, observed_on, detector, algo_version, metrics, valid_frac, confidence)
                           values (%s,%s,%s,'chlorophyll',%s,%s,%s,%s)
                           on conflict do nothing""",
                        (rid, scene_id, day, chl.ALGO_VERSION, json.dumps(m), m["valid_frac"],
                         chl.confidence(m, True)),
                    )
                    cur.execute("update core.reach set last_scored_at=now() where id=%s", (rid,))
                written += 1
                if written % 200 == 0:
                    conn.commit()
        finally:
            for s in srcs.values():
                s.close()
    conn.commit()
    log.info("scene %s: %d/%d reaches scored", scene_id, written, len(reaches))
    refresh_serving(conn, scene_id)
    return written


def refresh_serving(conn, scene_id: int) -> None:
    """Roll the scene's results into the ready-made tables the frontend reads. Never fails the scene."""
    try:
        with conn.cursor() as cur:
            cur.execute("select core.refresh_eo_serving(%s)", (scene_id,))
        conn.commit()
    except Exception:
        conn.rollback()
        log.exception("serving refresh failed for scene %s (nightly rebuild will repair)", scene_id)
