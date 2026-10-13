"""Push the cold archive (data/archive) to a Supabase Storage bucket. Private bucket 'archive'; object paths equal the local layout and the ops.archive_object ledger paths.
Needs SUPABASE_URL and SUPABASE_SERVICE_KEY in the environment (service key: `supabase projects api-keys --project-ref <ref>`). Only new or changed files are sent; the local
manifest data/archive/.uploaded.json records size per path. Usage: archive_sync.py [bucket]"""
import concurrent.futures as cf, json, os, sys
import httpx

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "data", "archive"))
URL = os.environ["SUPABASE_URL"].rstrip("/"); KEY = os.environ["SUPABASE_SERVICE_KEY"]; BUCKET = sys.argv[1] if len(sys.argv) > 1 else "archive"
H = {"Authorization": f"Bearer {KEY}", "apikey": KEY}
MAN = os.path.join(ROOT, ".uploaded.json"); done = json.load(open(MAN)) if os.path.exists(MAN) else {}
client = httpx.Client(headers=H, timeout=120)

r = client.get(f"{URL}/storage/v1/bucket/{BUCKET}")
if r.status_code != 200:
    r = client.post(f"{URL}/storage/v1/bucket", json={"id": BUCKET, "name": BUCKET, "public": False}); r.raise_for_status(); print("created private bucket", BUCKET)
files = []
for d, _, fs in os.walk(ROOT):
    for f in fs:
        if f.endswith(".parquet"):
            p = os.path.join(d, f); rel = os.path.relpath(p, ROOT); sz = os.path.getsize(p)
            if done.get(rel) != sz: files.append((rel, p, sz))
print(len(files), "files to upload,", round(sum(f[2] for f in files) / 1e6, 1), "MB", flush=True)

def up(item):
    rel, p, sz = item
    for attempt in range(4):
        try:
            r = httpx.post(f"{URL}/storage/v1/object/{BUCKET}/{rel}", headers={**H, "x-upsert": "true", "Content-Type": "application/octet-stream"}, content=open(p, "rb").read(), timeout=180)
            if r.status_code < 300: return rel, sz, None
            err = f"{r.status_code} {r.text[:120]}"
        except httpx.HTTPError as e: err = str(e)[:120]
    return rel, sz, err

ok = bad = 0
with cf.ThreadPoolExecutor(8) as ex:
    for rel, sz, err in ex.map(up, files):
        if err: bad += 1; print("FAILED", rel, err)
        else: done[rel] = sz; ok += 1
        if (ok + bad) % 200 == 0: print(ok + bad, "of", len(files), flush=True); json.dump(done, open(MAN, "w"))
json.dump(done, open(MAN, "w")); print(f"uploaded {ok}, failed {bad}")
