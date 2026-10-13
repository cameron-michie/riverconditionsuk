"""Waterbody drainage graph from the river network. Each waterbody drains to one downstream waterbody; unassigned links in between are walked through.
build() -> dict(wids, down{wid: wid|None}, area{wid: km2}, up_area{wid: km2}, order[wids upstream -> downstream], outlet_dist{wid: m to mouth})."""
import os, sys
sys.path[:0] = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "load")]
from collections import defaultdict

def build(cur):
    cur.execute("select id, start_node_id, end_node_id, waterbody_id, dist_to_mouth_m from geo.river_link where flow_direction = 'in direction' or flow_direction is null")
    links = cur.fetchall()
    starts = defaultdict(list)
    for lid, a, b, wb, d in links: starts[a].append((d, lid))
    by_id = {l[0]: l for l in links}
    cur.execute("select id, area_km2 from geo.waterbody where category = 'river' and area_km2 is not null"); area = dict(cur.fetchall())
    # outlet link of each waterbody: the one closest to the mouth
    outlet = {}
    for lid, a, b, wb, d in links:
        if wb in area and (wb not in outlet or d < outlet[wb][4]): outlet[wb] = (lid, a, b, wb, d)
    down = {}
    for wb, (lid, a, b, _, d) in outlet.items():
        node, cur_wb, tgt = b, wb, None
        for _ in range(60):
            nxt = sorted(starts.get(node, []))
            nxt = [by_id[l] for dd, l in nxt if dd is not None and dd <= d]            # downstream neighbours only
            if not nxt: break
            l2 = nxt[0]; node, d = l2[2], l2[4]
            if l2[3] is not None and l2[3] != wb and l2[3] in area: tgt = l2[3]; break
        down[wb] = tgt
    # topological order, upstream first (graph is a forest; guard against cycles)
    indeg = defaultdict(int)
    for w, t in down.items():
        if t is not None: indeg[t] += 1
    order, ready, seen = [], [w for w in down if indeg[w] == 0], set()
    while ready:
        w = ready.pop(); order.append(w); seen.add(w); t = down.get(w)
        if t is not None:
            indeg[t] -= 1
            if indeg[t] == 0: ready.append(t)
    order += [w for w in down if w not in seen]
    up_area = {w: area[w] for w in down}
    for w in order:
        t = down.get(w)
        if t is not None and w in seen: up_area[t] += up_area[w]
    return dict(wids=list(down), down=down, area=area, up_area=up_area, order=order, outlet_dist={w: outlet[w][4] for w in outlet})

if __name__ == "__main__":
    import numpy as np
    from db import connect
    with connect() as conn, conn.cursor() as cur:
        g = build(cur); print(len(g["wids"]), "waterbodies;", sum(1 for v in g["down"].values() if v is None), "outlets (to sea or off-network);", len(g["order"]) - len([w for w in g["order"] if True]) , "cycle guard")
        cur.execute("select waterbody_id, (attrs->>'catchment_area')::float8 from geo.site where waterbody_id is not null and attrs ? 'catchment_area'"); rows = cur.fetchall()
        r = np.array([g["up_area"][w] / a for w, a in rows if w in g["up_area"] and a and a > 5])
        print(len(r), "gauged waterbodies; model upstream area / NRFA catchment area: quantiles 10/25/50/75/90 =", np.round(np.quantile(r, [.1, .25, .5, .75, .9]), 2))
