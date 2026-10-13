"""Object storage for the cold archive (bucket 'archive', private) and weather frames (bucket 'weather', public).
Hosted (STORAGE_URL + STORAGE_KEY set): Supabase Storage over HTTP. Otherwise a local folder, so the same code runs on a laptop.
  s = store.archive()            s.put(rel, local_file)   s.get(rel, dest)   s.delete(rel)   s.hosted"""
import mimetypes, os, shutil, time, urllib.parse
import httpx

HERE = os.path.dirname(os.path.abspath(__file__)); DATA = os.path.abspath(os.path.join(HERE, "..", "..", "data"))
URL = os.environ.get("STORAGE_URL", "").rstrip("/"); KEY = os.environ.get("STORAGE_KEY", "")

class Store:
    def __init__(self, bucket, local_root):
        self.bucket, self.root, self.hosted = bucket, local_root, bool(URL and KEY)
        self.h = {"Authorization": f"Bearer {KEY}", "apikey": KEY}
        if not self.hosted: os.makedirs(self.root, exist_ok=True)
    def _u(self, rel): return f"{URL}/storage/v1/object/{self.bucket}/{urllib.parse.quote(rel)}"
    def put(self, rel, path):
        if not self.hosted:
            dest = os.path.join(self.root, rel)
            if os.path.abspath(dest) != os.path.abspath(path): os.makedirs(os.path.dirname(dest), exist_ok=True); shutil.copyfile(path, dest)
            return
        data = open(path, "rb").read(); err = None
        for t in range(6):
            try:
                r = httpx.post(self._u(rel), headers={**self.h, "x-upsert": "true", "Content-Type": mimetypes.guess_type(rel)[0] or "application/octet-stream"}, content=data, timeout=180)
                if r.status_code < 300: return
                err = f"{r.status_code} {r.text[:100]}"
            except httpx.HTTPError as e: err = str(e)[:100]
            time.sleep(2 * 2 ** t)
        raise RuntimeError(f"storage put {self.bucket}/{rel}: {err}")
    def get(self, rel, dest):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if not self.hosted: shutil.copyfile(os.path.join(self.root, rel), dest); return
        for t in range(5):
            r = httpx.get(self._u(rel), headers=self.h, timeout=180)
            if r.status_code == 200: open(dest, "wb").write(r.content); return
            time.sleep(2 * 2 ** t)
        raise RuntimeError(f"storage get {self.bucket}/{rel}: {r.status_code}")
    def delete(self, rel):
        if not self.hosted:
            try: os.remove(os.path.join(self.root, rel))
            except FileNotFoundError: pass
            return
        httpx.request("DELETE", f"{URL}/storage/v1/object/{self.bucket}", headers=self.h, json={"prefixes": [rel]}, timeout=60)

def archive(): return Store("archive", os.path.join(DATA, "archive"))
def weather(): return Store("weather", os.path.abspath(os.path.join(DATA, "..", "web")))      # local: files live under web/wx/... so the page can serve them

# Archive files are read from a local working copy. Hosted, that is /tmp/archive, filled from Storage on demand using the ledger.
ARCH_DIR = os.environ.get("ARCHIVE_DIR") or (("/tmp/archive") if URL and KEY else os.path.join(DATA, "archive"))
def fetch_archive(cur, dataset):
    """make sure every ledger file of this dataset is present under ARCH_DIR (no-op locally)."""
    if not (URL and KEY): return ARCH_DIR
    import concurrent.futures as cf
    cur.execute("select path from ops.archive_object where dataset = %s and bucket = 'archive'", (dataset,)); s = archive()
    todo = [p for (p,) in cur.fetchall() if not os.path.exists(os.path.join(ARCH_DIR, p))]
    with cf.ThreadPoolExecutor(8) as ex: list(ex.map(lambda p: s.get(p, os.path.join(ARCH_DIR, p)), todo))
    return ARCH_DIR
