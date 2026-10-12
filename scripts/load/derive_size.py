"""River size per link = total channel length upstream (a proxy for catchment area, hence width). Computed on an acyclic copy of the flow graph.
size_class = floor(log2(upstream_km + 1)): 1 km -> 1, 64 km -> 6, 1,000 km -> 9, 4,000 km -> 11. Drives map thinning and line width."""
import collections, time
from db import *
t0 = time.time()
with connect() as conn, conn.cursor() as cur:
    cur.execute("select id, start_node_id, end_node_id, coalesce(length_m, 0), flow_direction from core.river_link")
    L = cur.fetchall(); n = len(L); lid = [r[0] for r in L]; ln = [float(r[3]) for r in L]
    s = [r[1] for r in L]; e = [r[2] for r in L]
    for i, r in enumerate(L):
        if r[4] == "in opposite direction": s[i], e[i] = e[i], s[i]
    out_at = collections.defaultdict(list)
    for i in range(n): out_at[s[i]].append(i)
    down_all = [[j for j in out_at.get(e[i], []) if j != i] for i in range(n)]
    state = [0] * n; order = []; down = [[] for _ in range(n)]
    for root in range(n):
        if state[root]: continue
        stack = [(root, iter(down_all[root]))]; state[root] = 1
        while stack:
            u, it = stack[-1]
            for v in it:
                if state[v] == 1: continue
                down[u].append(v)
                if state[v] == 0: state[v] = 1; stack.append((v, iter(down_all[v]))); break
            else: state[u] = 2; order.append(u); stack.pop()
    ups = [[] for _ in range(n)]
    for u in range(n):
        for v in down[u]: ups[v].append(u)
    up = [0.0] * n
    for u in reversed(order):                       # upstream first
        up[u] = ln[u] + sum(up[k] / len(down[k]) for k in ups[u])      # conservative: a distributary splits its load, so braids cannot double-count
    import math
    cur.execute("create temp table stg_sz (id bigint, km real, sc smallint) on commit drop")
    copy_rows(cur, "stg_sz", ["id", "km", "sc"], ((lid[i], up[i] / 1000, int(math.floor(math.log2(up[i] / 1000 + 1)))) for i in range(n)))
    cur.execute("alter table core.river_link add column if not exists upstream_km real, add column if not exists size_class smallint")
    cur.execute("update core.river_link l set upstream_km = t.km, size_class = t.sc from stg_sz t where t.id = l.id")
    cur.execute("select size_class, count(*) from core.river_link group by 1 order by 1"); print(cur.fetchall())
    conn.commit()
print("done", round(time.time() - t0, 1), "s")
