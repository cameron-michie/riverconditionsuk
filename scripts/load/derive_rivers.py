"""Derive core.river from topology + names; compute strahler & dist_to_mouth; build tributary tree."""
import re, time, collections
from db import *

# Bilingual names that denote one river. Key = any spelling, value = canonical English key.
ALIAS = {
 "Afon Gwy": "River Wye", "Afon Hafren": "River Severn", "Afon Dyfrdwy": "River Dee", "Afon Wysg": "River Usk",
 "Afon Mynwy": "River Monnow", "Afon Efyrnwy": "River Vyrnwy", "Afon Tywi": "River Towy", "Afon Dyfi": "River Dovey",
 "Afon Rhymni": "River Rhymney", "Afon Ebwy": "River Ebbw", "Afon Nedd": "River Neath", "Afon Llwchwr": "River Loughor",
 "Afon Taf": "River Taff", "Afon Elái": "River Ely", "Afon Hepste": "River Hepste",
 "Afon Tefeidiad": "River Teme", "Afon Gwy ": "River Wye", "Afon Ieithon": "River Ithon", "Afon Clwyd": "River Clwyd",
}
def slug(s): return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
t0 = time.time()
with connect() as conn, conn.cursor() as cur:
    cur.execute("update core.river_link set river_id = null"); cur.execute("update core.site set river_id = null where river_id is not null"); cur.execute("update core.survey set river_id = null where river_id is not null")
    cur.execute("truncate core.waterbody_river"); cur.execute("delete from core.signal where entity_kind = 'river'"); cur.execute("delete from research.work_place where place_kind = 'river' and method = 'rule'")
    cur.execute("delete from core.river_alias"); cur.execute("delete from core.river")
    cur.execute("select id, name, start_node_id, end_node_id, coalesce(length_m,0), form, flow_direction from core.river_link")
    L = cur.fetchall()
    cur.execute("select id, ST_X(geom), ST_Y(geom), category from core.river_node")
    rows_n = cur.fetchall(); XY = {i: (x, y) for i, x, y, c in rows_n}; CAT = {i: c for i, x, y, c in rows_n}
    n = len(L); print("links", n, "nodes", len(XY))
    lid = [r[0] for r in L]; idx = {l: i for i, l in enumerate(lid)}
    name = [r[1] for r in L]; s = [r[2] for r in L]; e = [r[3] for r in L]
    ln = [float(r[4]) for r in L]; form = [r[5] for r in L]
    for i, r in enumerate(L):
        if r[6] == "in opposite direction": s[i], e[i] = e[i], s[i]
    out_at = collections.defaultdict(list); in_at = collections.defaultdict(list)
    for i in range(n): out_at[s[i]].append(i); in_at[e[i]].append(i)

    # ── acyclic flow graph: drop DFS back-edges (braided channels / loops) so every quantity below is well defined
    down_all = [[j for j in out_at.get(e[i], []) if j != i] for i in range(n)]
    state = [0] * n; order = []; removed = 0
    down = [[] for _ in range(n)]
    for root in range(n):
        if state[root]: continue
        stack = [(root, iter(down_all[root]))]; state[root] = 1
        while stack:
            u, it = stack[-1]
            for v in it:
                if state[v] == 1: removed += 1; continue          # back edge: closes a cycle
                down[u].append(v)
                if state[v] == 0: state[v] = 1; stack.append((v, iter(down_all[v]))); break
            else:
                state[u] = 2; order.append(u); stack.pop()         # post-order: downstream links come first
    ups = [[] for _ in range(n)]
    for u in range(n):
        for v in down[u]: ups[v].append(u)
    print("cycle edges removed:", removed)
    # ── dist_to_mouth = LONGEST path to an outlet along the DAG (the main stem beats short distributaries and dead-end spurs)
    dist = [0.0] * n
    for u in order:                       # downstream first
        dist[u] = ln[u] + (max((dist[v] for v in down[u]), default=0.0))
    # ── Strahler on the DAG
    strahler = [0] * n
    for u in reversed(order):             # upstream first
        o = [strahler[k] for k in ups[u]]
        strahler[u] = 1 if not o else (max(o) + 1 if o.count(max(o)) > 1 else max(o))
    print("strahler max", max(strahler))

    # ── bridge unnamed lake/tidal/canal links between two links of the same river name
    key = [ALIAS.get(x, x) if x else None for x in name]
    for _ in range(3):
        names_at = collections.defaultdict(set)
        for i in range(n):
            if key[i]: names_at[s[i]].add(key[i]); names_at[e[i]].add(key[i])
        ch = 0
        for i in range(n):
            if key[i] is None and form[i] in ("lake", "tidalRiver", "canal", "inlandRiver"):
                c = names_at[s[i]] & names_at[e[i]]
                if len(c) == 1: key[i] = next(iter(c)); ch += 1
        if not ch: break

    # ── connected components per key (union-find over shared nodes)
    parent = list(range(n))
    def find(x):
        while parent[x] != x: parent[x] = parent[parent[x]]; x = parent[x]
        return x
    node_owner = {}
    for i in range(n):
        if not key[i]: continue
        for nd in (s[i], e[i]):
            tag = (nd, key[i])
            if tag in node_owner: parent[find(i)] = find(node_owner[tag])
            else: node_owner[tag] = i
    comp = collections.defaultdict(list)
    for i in range(n):
        if key[i]: comp[find(i)].append(i)
    print("river components", len(comp), "in", round(time.time() - t0, 1), "s")

    # ── continuation merge: follow the MAIN STEM downstream from each component's mouth. If the same river name resumes
    #    (possibly after short differently-named reaches such as "Trent Falls" or "Sonning Reach"), it is one river: merge them all.
    def comp_mouth(mem):
        mx = max(strahler[i] for i in mem)
        return min((i for i in mem if strahler[i] == mx), key=lambda i: dist[i])
    for pas in range(5):
        owner = {}
        for r, mem in comp.items():
            for i in mem: owner[i] = r
        merged = 0
        for r in sorted(comp.keys(), key=lambda r: -len(comp[r])):
            if r not in comp: continue
            mem = comp[r]; node = e[comp_mouth(mem)]; hops = 0; tgt = None; skip = []
            while hops < 120:
                outs = out_at.get(node, [])
                if not outs: break
                j = max(outs, key=lambda j: dist[j])
                oj = owner.get(j)
                if oj is not None and oj != r and oj in comp:
                    if key[comp[oj][0]] == key[mem[0]]: tgt = oj; break
                    if oj not in skip:
                        if sum(ln[i] for i in comp[oj]) > 30000: break     # a genuinely different, long river
                        skip.append(oj)
                node = e[j]; hops += 1
            if tgt is not None:
                for c in [r] + skip:
                    if c in comp and c != tgt: comp[tgt].extend(comp[c]); [owner.__setitem__(i, tgt) for i in comp[c]]; del comp[c]
                merged += 1
        print("merge pass", pas, "merged", merged, "components", len(comp))
        if not merged: break

    # ── river rows
    rivers = []   # (slug, name, name_cy, mouth_node, source_node, length_km, strahler_max, members)
    used = collections.Counter()
    for root, mem in comp.items():
        raw = collections.Counter(name[i] for i in mem if name[i])
        canon = key[mem[0]]
        cy = next((w for w in raw if ALIAS.get(w) == canon), None) if raw else None
        nm = canon
        mouth = comp_mouth(mem)
        top = max(mem, key=lambda i: dist[i])
        x, y = XY[e[mouth]]
        sl = f"{slug(nm)}-{abs(y):.2f}{'n' if y >= 0 else 's'}-{abs(x):.2f}{'e' if x >= 0 else 'w'}"
        used[sl] += 1
        if used[sl] > 1: sl += f"-{used[sl]}"
        rivers.append((sl, nm, cy, e[mouth], s[top], sum(ln[i] for i in mem) / 1000, max(strahler[i] for i in mem), mem))
    cur.execute("create temp table stg_river (ord int, slug text, name text, name_cy text, mouth_node_id bigint, source_node_id bigint, length_km double precision, strahler_max smallint) on commit drop")
    copy_rows(cur, "stg_river", ["ord", "slug", "name", "name_cy", "mouth_node_id", "source_node_id", "length_km", "strahler_max"],
              ((i, r[0], r[1], r[2], r[3], r[4], r[5], r[6]) for i, r in enumerate(rivers)))
    cur.execute("""insert into core.river (slug, name, name_cy, mouth_node_id, source_node_id, length_km, strahler_max)
                   select slug, name, name_cy, mouth_node_id, source_node_id, length_km, strahler_max from stg_river order by ord""")
    cur.execute("select slug, id from core.river"); rid_of_slug = dict(cur.fetchall())
    link_river = {}
    for r in rivers:
        for i in r[7]: link_river[i] = rid_of_slug[r[0]]
    cur.execute("create temp table stg_lr (link_id bigint, river_id bigint, strahler smallint, dist double precision) on commit drop")
    copy_rows(cur, "stg_lr", ["link_id", "river_id", "strahler", "dist"], ((lid[i], link_river.get(i), strahler[i] or None, dist[i]) for i in range(n)))
    cur.execute("""update core.river_link l set river_id = t.river_id, strahler = t.strahler, dist_to_mouth_m = t.dist
                   from stg_lr t where t.link_id = l.id""")

    # ── tributary tree: from each river's mouth, walk downstream (<=40 hops) to the first link of a different river
    parent_of = {}
    for r in rivers:
        me = rid_of_slug[r[0]]; node = r[3]; hops = 0; found = None
        while node is not None and hops < 40 and found is None:
            outs = [j for j in out_at.get(node, [])]
            if not outs: break
            j = max(outs, key=lambda j: dist[j])
            rv = link_river.get(j)
            if rv and rv != me: found = rv; break
            node = e[j]; hops += 1
        if found: parent_of[me] = found
    cur.execute("create temp table stg_par (id bigint, parent bigint) on commit drop")
    copy_rows(cur, "stg_par", ["id", "parent"], parent_of.items())
    cur.execute("update core.river r set parent_river_id = p.parent from stg_par p where p.id = r.id")

    # aliases (Welsh/English)
    cur.execute("""insert into core.river_alias (river_id, alias, lang)
                   select id, name_cy, 'cy' from core.river where name_cy is not null
                   union select id, name, 'en' from core.river where name_cy is not null on conflict do nothing""")
    # geometry: merge + simplify (~30 m) for display
    cur.execute("""update core.river r set geom = g.geom from (
                     select river_id, ST_Multi(ST_SimplifyPreserveTopology(ST_LineMerge(ST_Collect(geom)), 0.0003)) geom
                     from core.river_link where river_id is not null group by river_id) g where g.river_id = r.id""")
    cur.execute("select count(*), count(parent_river_id), sum((geom is not null)::int) from core.river"); print("rivers (total, with parent, with geom):", cur.fetchone())
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
