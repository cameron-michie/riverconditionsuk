"""Snapshot every api function the web app calls, for a fixed sample, so a schema change can be checked for parity.

    python api_snapshot.py <out_dir> [--ids ids.json]

The first run picks the sample and writes it to <out_dir>/ids.json; later runs reuse it with --ids so before and after
use the same entities. Compare two snapshots with  python api_snapshot.py --diff <before_dir> <after_dir>.
"""
import json, math, os, sys
import psycopg

DB = os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")

def tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return x, y

PLACES = [(-2.72, 52.05), (-1.25, 51.75), (-3.2, 55.95)]   # Wye at Hereford, Thames at Oxford, Edinburgh

def pick(cur):
    q = lambda sql: [r[0] for r in cur.execute(sql).fetchall()]
    return dict(
        gauges=q("select site_id from core.gauge_state where flow is not null order by site_id limit 3")
             + q("select site_id from core.gauge_state where flow is null order by site_id limit 2"),
        stretches=q("select waterbody_id from core.waterbody_map_state order by waterbody_id limit 3")
             + q("select wr.waterbody_id from core.waterbody_river wr join core.river r on r.id = wr.river_id where r.slug = 'river-wye-51.60n-2.66w' order by 1 limit 3"),
        rivers=q("select slug from core.river order by length_km desc nulls last limit 4") + ["river-wye-51.60n-2.66w"],
        works=q("select w.id from core.sewage_works w where w.monitor_site_id is not null order by w.id limit 2"),
        volunteer=q("select site_id from core.survey where site_id is not null group by 1 order by count(*) desc limit 2"),
        layers=q("select code from core.map_layer order by code"),
    )

CALLS = {
    "ui_config": "select api.ui_config()",
    "weather": "select api.weather(null)",
    "search": "select jsonb_agg(to_jsonb(s)) from api.search_rivers('wye') s",
}

def run(cur, ids):
    out = {k: cur.execute(v).fetchone()[0] for k, v in CALLS.items()}
    for g in ids["gauges"]:
        out[f"gauge_{g}"] = cur.execute("select api.gauge_dossier(%s)", (g,)).fetchone()[0]
    for s in ids["stretches"]:
        out[f"stretch_{s}"] = cur.execute("select api.stretch_dossier(%s)", (s,)).fetchone()[0]
        out[f"stretch_geom_{s}"] = cur.execute("select api.stretch_geom(%s)", (s,)).fetchone()[0]
        out[f"outlook_{s}"] = cur.execute("select api.flow_outlook(%s)", (s,)).fetchone()[0]
    for r in ids["rivers"]:
        out[f"river_{r}"] = cur.execute("select api.river_dossier(%s)", (r,)).fetchone()[0]
        out[f"river_geom_{r}"] = cur.execute("select api.river_geom(%s)", (r,)).fetchone()[0]
    for w in ids["works"]:
        out[f"works_{w}"] = cur.execute("select api.works_dossier(%s)", (w,)).fetchone()[0]
    for v in ids["volunteer"]:
        out[f"volunteer_{v}"] = cur.execute("select api.volunteer_dossier(%s)", (v,)).fetchone()[0]
    for i, (lon, lat) in enumerate(PLACES):
        out[f"area_{i}"] = cur.execute("select api.area_summary(%s,%s,%s,%s)", (lon - .3, lat - .2, lon + .3, lat + .2)).fetchone()[0]
        for z in (6, 8, 10, 13):
            x, y = tile(lon, lat, z)
            for l in ids["layers"]:
                out[f"tile_{l}_{z}_{i}"] = cur.execute("select api.map_tile(%s,%s,%s,%s)", (l, z, x, y)).fetchone()[0]
    return out

def shape(v, path=""):
    """Set of key paths: what the frontend depends on."""
    s = set()
    if isinstance(v, dict):
        for k, x in v.items():
            s.add(f"{path}.{k}"); s |= shape(x, f"{path}.{k}")
    elif isinstance(v, list):
        for x in v[:50]:
            s |= shape(x, f"{path}[]")
    return s

def diff(a_dir, b_dir):
    a = json.load(open(os.path.join(a_dir, "snapshot.json"))); b = json.load(open(os.path.join(b_dir, "snapshot.json")))
    bad = 0
    for k in sorted(a):
        if k not in b:
            print(f"MISSING call {k}"); bad += 1; continue
        sa, sb = shape(a[k]), shape(b[k])
        lost, gained = sorted(sa - sb), sorted(sb - sa)
        na = len(a[k].get("features", [])) if isinstance(a[k], dict) else None
        nb = len(b[k].get("features", [])) if isinstance(b[k], dict) else None
        if lost or gained or na != nb:
            bad += 1
            print(f"{k}: lost={lost[:12]} gained={gained[:12]}" + (f" features {na}->{nb}" if na != nb else ""))
    print(f"{len(a)} calls compared, {bad} differ")

if __name__ == "__main__":
    if sys.argv[1] == "--diff":
        diff(sys.argv[2], sys.argv[3]); sys.exit()
    out_dir = sys.argv[1]; os.makedirs(out_dir, exist_ok=True)
    with psycopg.connect(DB) as con, con.cursor() as cur:
        if "--ids" in sys.argv:
            ids = json.load(open(sys.argv[sys.argv.index("--ids") + 1]))
        else:
            ids = pick(cur)
            json.dump(ids, open(os.path.join(out_dir, "ids.json"), "w"), indent=1)
        snap = run(cur, ids)
    json.dump(snap, open(os.path.join(out_dir, "snapshot.json"), "w"), default=str)
    print(f"{len(snap)} calls -> {out_dir}")
