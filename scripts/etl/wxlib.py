"""Weather helpers shared by the radar and forecast jobs: the Met Office radar grid, the map image grid, colour ramps."""
import math, os
import numpy as np
from pyproj import Transformer

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
HOSTED = bool(os.environ.get("STORAGE_URL") and os.environ.get("STORAGE_KEY"))
WX_DIR = "/tmp/wx" if HOSTED else os.path.join(ROOT, "web", "wx")        # scratch when hosted (frames live in the public Storage bucket 'weather'); beside the page locally

# Radar composite: 1 km OSGB-style transverse Mercator, origin upper left (ODIM attributes of the 2026 files).
RADAR_PROJ = "+proj=tmerc +lat_0=49 +lon_0=-2 +k=0.999601 +x_0=400000 +y_0=-100000 +ellps=airy +units=m"
RADAR_UL = (-17.973932221553792, 62.92071695962483)      # lon, lat
RADAR_SHAPE = (2175, 1725)                                # rows (y), cols (x)
_to_radar = Transformer.from_crs("EPSG:4326", RADAR_PROJ, always_xy=True)
RX0, RY0 = _to_radar.transform(*RADAR_UL)

def lonlat_to_cell(lon, lat):
    x, y = _to_radar.transform(lon, lat)
    return np.floor((np.asarray(x) - RX0) / 1000).astype(int), np.floor((RY0 - np.asarray(y)) / 1000).astype(int)

# Map image: Web Mercator-linear raster over the UK, so the canvas can place it with two projected corners.
BBOX = (-8.8, 49.7, 2.0, 61.0)      # minlon, minlat, maxlon, maxlat
W = 900
def _my(lat): return math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))
def _lat(my): return math.degrees(2 * math.atan(math.exp(my)) - math.pi / 2)
_dx = math.radians(BBOX[2] - BBOX[0]) / W
H = round((_my(BBOX[3]) - _my(BBOX[1])) / _dx)
def image_grid():
    """lon/lat of every output pixel centre (H x W)."""
    lons = BBOX[0] + (np.arange(W) + 0.5) * (BBOX[2] - BBOX[0]) / W
    lats = np.array([_lat(_my(BBOX[3]) - (i + 0.5) * (_my(BBOX[3]) - _my(BBOX[1])) / H) for i in range(H)])
    return np.meshgrid(lons, lats)

# Rain ramp: low-saturation violet, kept away from the blue/yellow/orange/red that mean river condition.
RAIN_STOPS = [0.1, 0.5, 1, 2, 4, 8, 16, 32]
RAIN_RGBA = np.array([[226, 218, 240, 70], [205, 187, 227, 110], [176, 144, 208, 140], [138, 96, 184, 165],
                      [106, 63, 160, 190], [74, 37, 128, 210], [46, 18, 96, 225], [26, 8, 64, 240]], dtype=float)
def rain_rgba(rate):
    """mm/h array -> uint8 RGBA (H, W, 4). Below 0.1 mm/h and nodata are fully transparent."""
    out = np.zeros(rate.shape + (4,), dtype=np.uint8)
    ok = np.isfinite(rate) & (rate >= RAIN_STOPS[0])
    lr = np.log(np.clip(rate[ok], RAIN_STOPS[0], RAIN_STOPS[-1])); ls = np.log(RAIN_STOPS)
    for c in range(4): out[..., c][ok] = np.interp(lr, ls, RAIN_RGBA[:, c]).astype(np.uint8)
    return out
