"""Development helper: re-apply every function and view from supabase/schemas to a database (create or replace), then call each
api function once so a broken body fails here instead of in the browser. Tables are untouched; schema changes go through
`supabase db schema declarative sync`.
    python dev_apply_functions.py [database-url]"""
import glob, os, re, sys
import psycopg

DB = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@127.0.0.1:54322/postgres")
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "supabase", "schemas")

def statements(sql):
    """function and view definitions, in file order"""
    out = []
    for m in re.finditer(r"^create function .*?\$\$;[ \t]*$|^create view .*?;[ \t]*\n(?:\n|\Z)", sql, re.S | re.M):
        out.append((m.start(), m.group(0).rstrip()))
    return [s for _, s in sorted(out)]

with psycopg.connect(DB, autocommit=False) as con, con.cursor() as cur:
    n = 0
    for f in sorted(glob.glob(os.path.join(ROOT, "*.sql"))):
        for st in statements(open(f).read()):
            st = re.sub(r"^create (function|view)", lambda m: f"create or replace {m.group(1)}", st, count=1)
            cur.execute(st); n += 1
    con.commit()
    print(f"applied {n} functions and views")
    checks = {
        "ui_config": "select api.ui_config()", "weather": "select api.weather(null)", "search": "select count(*) from api.search_rivers('wye')",
        "gauge": "select api.gauge_dossier((select site_id from live.site_now where kind = 'gauge' limit 1))",
        "stretch": "select api.stretch_dossier((select id from geo.waterbody where line_geom is not null limit 1))",
        "stretch_geom": "select api.stretch_geom((select id from geo.waterbody where line_geom is not null limit 1))",
        "outlook": "select api.flow_outlook((select waterbody_id from live.waterbody_now where flow_days is not null limit 1))",
        "river": "select api.river_dossier((select slug from geo.river order by length_km desc nulls last limit 1))",
        "river_geom": "select api.river_geom((select slug from geo.river order by length_km desc nulls last limit 1))",
        "works": "select api.works_dossier((select id from geo.site where kind = 'sewage_works' and attrs ? 'works' limit 1))",
        "volunteer": "select api.volunteer_dossier((select id from geo.site where kind = 'survey_site' limit 1))",
        "area": "select api.area_summary(-3, 51.8, -2.4, 52.2)",
        "tiles": "select count(*) from ref.map_layer l, lateral api.map_tile(l.code, 10, 505, 340) t",
    }
    bad = 0
    for k, q in checks.items():
        try:
            cur.execute(q); cur.fetchone()
        except Exception as e:
            bad += 1; print(f"FAIL {k}: {str(e).splitlines()[0]}"); con.rollback()
    print("all api functions answer" if not bad else f"{bad} failing")
