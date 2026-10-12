"""Rule-based research->river place proposals. Precision over recall: only distinctive names, only 'River X' / 'X catchment|basin|valley' in the title.
These are PROPOSALS (status='proposed', method='rule'): the LLM geolocation agent + critic + human gate replace/confirm them later."""
import re, collections, time
from db import *
t0 = time.time()
AMBIG = {"avon","stour","derwent","dee","don","eden","frome","trent","ouse","test","wear","tyne","tees","esk","exe","axe","cam","lea","lee","colne","ember","mole","wey","wye_x","tame","aire","calder","nene","welland","witham","yare","bure","waveney","orwell","stour_x","ure","swale","nidd","wharfe","tweed","till","usk_x"}
with connect() as conn, conn.cursor() as cur:
    cur.execute("""select distinct on (lower(regexp_replace(name, '^(River|Afon) ', '')))
                          id, name, regexp_replace(name, '^(River|Afon) ', '') short, length_km
                   from core.river where length_km >= 40 and name ~ '^(River|Afon) ' order by lower(regexp_replace(name, '^(River|Afon) ', '')), length_km desc""")
    rivers = cur.fetchall()
    # a name is "distinctive" if it is not a notorious duplicate and there is only one river of that name >= 40km
    cur.execute("select lower(regexp_replace(name,'^(River|Afon) ','')) k, count(*) from core.river where length_km >= 40 and name ~ '^(River|Afon) ' group by 1")
    dup = {k for k, n in cur.fetchall() if n > 2}
    pats = []
    for rid, name, short, km in rivers:
        k = short.lower()
        if k in AMBIG or k in dup or len(short) < 3: continue
        pats.append((rid, short, re.compile(rf"\b(?:River|Afon) {re.escape(short)}\b|\b{re.escape(short)} (?:catchment|basin|valley|estuary|river)\b", re.I if False else 0)))
    print("distinctive river patterns:", len(pats))
    cur.execute("select id, title, coalesce(abstract,'') from research.work")
    rows = []; per = collections.Counter()
    for wid, title, ab in cur.fetchall():
        for rid, short, pat in pats:
            m = pat.search(title)
            conf = 0.7 if m else None
            if not m and ab:
                m = pat.search(ab); conf = 0.5 if m else None
            if m:
                rows.append((wid, "river", rid, m.group(0), conf, "rule", f"title/abstract match: '{m.group(0)}'", "proposed")); per[short] += 1
    copy_rows(cur, "research.work_place", ["work_id", "place_kind", "place_id", "place_text", "confidence", "method", "evidence_span", "status"], rows) if rows else None
    print("proposals", len(rows), "top rivers:", per.most_common(10))
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
