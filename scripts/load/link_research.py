"""Research papers per river, straight from the OpenAlex download (data/raw/research/openalex_works.json) into geo.river.research.
Rule-based: precision over recall. Only distinctive river names, and only 'River X' / 'X catchment|basin|valley|estuary|river' in the title (confidence 0.7)
or abstract (0.5). Each river keeps its 8 best matches, most confident and most cited first."""
import collections, json, os, re, time
from db import *
t0 = time.time()
AMBIG = {"avon","stour","derwent","dee","don","eden","frome","trent","ouse","test","wear","tyne","tees","esk","exe","axe","cam","lea","lee","colne","ember","mole","wey","wye_x","tame","aire","calder","nene","welland","witham","yare","bure","waveney","orwell","stour_x","ure","swale","nidd","wharfe","tweed","till","usk_x"}
KEEP = 8

def abstract(ix):
    if not ix: return ""
    pos = {}
    for w, ps in ix.items():
        for p in ps: pos[p] = w
    return " ".join(pos[k] for k in sorted(pos))

with connect() as conn, conn.cursor() as cur:
    cur.execute("""select distinct on (lower(regexp_replace(name, '^(River|Afon) ', '')))
                          id, name, regexp_replace(name, '^(River|Afon) ', '') short, length_km
                   from geo.river where length_km >= 40 and name ~ '^(River|Afon) ' order by lower(regexp_replace(name, '^(River|Afon) ', '')), length_km desc""")
    rivers = cur.fetchall()
    # a name is "distinctive" if it is not a notorious duplicate and there are at most two rivers of that name >= 40 km
    cur.execute("select lower(regexp_replace(name,'^(River|Afon) ','')) k, count(*) from geo.river where length_km >= 40 and name ~ '^(River|Afon) ' group by 1")
    dup = {k for k, n in cur.fetchall() if n > 2}
    pats = []
    for rid, name, short, km in rivers:
        k = short.lower()
        if k in AMBIG or k in dup or len(short) < 3: continue
        pats.append((rid, short, re.compile(rf"\b(?:River|Afon) {re.escape(short)}\b|\b{re.escape(short)} (?:catchment|basin|valley|estuary|river)\b")))
    print("distinctive river patterns:", len(pats))
    works = json.load(open(os.path.join(RAW, "research", "openalex_works.json")))
    found = collections.defaultdict(list)
    for w in works:
        title = w.get("title") or w.get("display_name") or ""; ab = abstract(w.get("abstract_inverted_index"))
        loc = w.get("best_oa_location") or w.get("primary_location") or {}; prim = w.get("primary_location") or {}
        for rid, short, pat in pats:
            conf = 0.7 if pat.search(title) else 0.5 if ab and pat.search(ab) else None
            if conf is None: continue
            found[rid].append((conf, w.get("cited_by_count") or 0, {
                "title": title or "(untitled)", "year": w.get("publication_year"), "venue": (prim.get("source") or {}).get("display_name"),
                "authors": [(a.get("author") or {}).get("display_name") for a in (w.get("authorships") or [])[:3]],
                "url": prim.get("landing_page_url") or (w.get("doi") and ("https://doi.org/" + w["doi"].removeprefix("https://doi.org/"))),
                "oa": (w.get("open_access") or {}).get("oa_status"), "licence": loc.get("license") or prim.get("license"), "reviewed": False, "confidence": conf}))
    rows = [(rid, jdump([x[2] for x in sorted(v, key=lambda x: (-x[0], -x[1]))[:KEEP]])) for rid, v in found.items()]
    cur.execute("update geo.river set research = '[]' where research <> '[]'")
    cur.execute("create temp table stg_r (id bigint, research text) on commit drop"); copy_rows(cur, "stg_r", ["id", "research"], rows)
    cur.execute("update geo.river r set research = s.research::jsonb from stg_r s where s.id = r.id")
    print("rivers with research", len(rows), "papers matched", sum(len(v) for v in found.values()))
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
