import os

DATABASE_URL = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
STAC_URL = os.environ.get("STAC_URL", "https://earth-search.aws.element84.com/v1")
S2_COLLECTION = "sentinel-2-c1-l2a"
UK_BBOX = (-8.7, 49.8, 2.0, 60.9)          # lon/lat envelope of the UK
MAX_CLOUD = float(os.environ.get("MAX_CLOUD", "60"))
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "10"))
WATCH_INTERVAL_S = int(os.environ.get("WATCH_INTERVAL_S", "3600"))
QUEUE = "eo_jobs"
BACKFILL_DAYS = int(os.environ.get("BACKFILL_DAYS", "30"))
VISIBILITY_S = int(os.environ.get("VISIBILITY_S", "3600"))  # job re-appears if the worker dies mid-scene; must exceed the slowest scene
HEALTH_PORT = int(os.environ.get("PORT", "8080"))
BANDS = {"b3": "green", "b4": "red", "b5": "rededge1", "b8": "nir", "scl": "scl"}   # Earth Search asset names
