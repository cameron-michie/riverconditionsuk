"""Shared helpers: polite HTTP with retries, raw-file saving, provenance manifest."""
import hashlib, json, os, time, datetime as dt, threading
import httpx

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "raw")
UA = "riverconditionsuk/0.1 (open-data research)"
_lock = threading.Lock()
_client = httpx.Client(headers={"User-Agent": UA}, timeout=120, follow_redirects=True,
                       limits=httpx.Limits(max_connections=16))

_hosts = {}
_MIN_GAP = float(os.environ.get("MIN_GAP", "0.35"))   # seconds between requests to one host

def _throttle(url):
    host = httpx.URL(url).host
    with _lock:
        h = _hosts.setdefault(host, {"next": 0.0})
        now = time.monotonic()
        wait = max(0.0, h["next"] - now)
        h["next"] = max(now, h["next"]) + _MIN_GAP
    if wait:
        time.sleep(wait)

# On Supabase Compute the egress IP is a US cloud address that the EA's hydrology and linked-data (doc/) APIs refuse. Where EA_PROXY_URL is set, those two paths go through an
# Edge Function pinned to London (x-region: the EA also blocks US egress, and a function otherwise runs near its caller) (supabase/functions/eaproxy). Everything else, and every local run, is untouched.
PROXY, PTOK = os.environ.get("EA_PROXY_URL"), os.environ.get("EA_PROXY_TOKEN")
def _via_proxy(url, params, headers):
    if PROXY and (url.startswith("https://environment.data.gov.uk/hydrology") or url.startswith("https://environment.data.gov.uk/doc/")):
        return PROXY, {"u": str(httpx.URL(url).copy_merge_params(params or {}))}, {**(headers or {}), "x-etl-token": PTOK, "x-region": os.environ.get("EA_PROXY_REGION", "eu-west-2")}
    return url, params, headers

def get(url, params=None, headers=None, tries=6, **kw):
    url, params, headers = _via_proxy(url, params, headers)
    for i in range(tries):
        try:
            _throttle(url)
            r = _client.get(url, params=params, headers=headers, **kw)
            if r.status_code in (403, 429, 500, 502, 503, 504):
                raise httpx.HTTPError(f"{r.status_code}")
            return r
        except httpx.HTTPError:
            if i == tries - 1:
                raise
            time.sleep(min(60, 3 * 2 ** i))

def post(url, json_body=None, headers=None, tries=4, **kw):
    for i in range(tries):
        try:
            r = _client.post(url, json=json_body, headers=headers, **kw)
            if r.status_code in (429, 500, 502, 503, 504):
                raise httpx.HTTPError(f"{r.status_code}")
            return r
        except httpx.HTTPError:
            if i == tries - 1:
                raise
            time.sleep(2 ** i)

def save(source, name, data, url="", licence="OGL-3.0", note=""):
    """Write bytes/str/obj under data/raw/<source>/<name> and append to manifest.jsonl."""
    d = os.path.join(ROOT, source)
    os.makedirs(d, exist_ok=True)
    if not isinstance(data, (bytes, bytearray)):
        data = (data if isinstance(data, str) else json.dumps(data)).encode()
    p = os.path.join(d, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data)
    rec = dict(source=source, file=f"{source}/{name}", url=str(url), bytes=len(data),
               sha256=hashlib.sha256(data).hexdigest(), licence=licence, note=note,
               fetched_at=dt.datetime.now(dt.timezone.utc).isoformat())
    with _lock, open(os.path.join(ROOT, "manifest.jsonl"), "a") as m:
        m.write(json.dumps(rec) + "\n")
    return p

def log(source, msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {source}: {msg}", flush=True)

def arcgis_all(layer_url, where="1=1", out_fields="*", page=None, geometry=True):
    """Page through an ArcGIS FeatureServer layer, returning GeoJSON features."""
    meta = get(layer_url, params={"f": "json"}).json()
    page = page or min(meta.get("maxRecordCount", 1000), 2000)
    feats, off = [], 0
    while True:
        r = get(layer_url + "/query", params={"where": where, "outFields": out_fields, "f": "geojson",
                "outSR": 4326, "resultOffset": off, "resultRecordCount": page,
                "returnGeometry": "true" if geometry else "false", "orderByFields": meta.get("objectIdField") or "OBJECTID"}).json()
        fs = r.get("features", [])
        feats += fs
        if len(fs) < page and not r.get("exceededTransferLimit"):
            break
        off += len(fs)
        if not fs:
            break
    return feats, meta

def getj(url, params=None, headers=None, tries=6, **kw):
    """GET and parse JSON, retrying on transport errors and non-JSON bodies."""
    for i in range(tries):
        try:
            r = get(url, params=params, headers=headers, tries=2, **kw)
            return r.json()
        except Exception:
            if i == tries - 1:
                raise
            time.sleep(1.5 * (i + 1))
