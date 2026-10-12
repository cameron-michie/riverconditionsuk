"""EA stage scale per level station: typical range, highest recent, record max/min, datum. Needed for a per-gauge flood index."""
import concurrent.futures as cf, json, os
from lib import *
S = "ea_flood"; B = "https://environment.data.gov.uk/flood-monitoring"
st = json.load(open(os.path.join(ROOT, S, "stations.json")))["items"]
refs = [s["stationReference"] for s in st if any(m.get("parameter") == "level" for m in s.get("measures", [])) and s.get("stageScale")]
log(S, f"level stations with a stage scale: {len(refs)}")
out_p = os.path.join(ROOT, S, "stagescale.json"); out = json.load(open(out_p)) if os.path.exists(out_p) else {}
def one(ref):
    if ref in out: return ref, None
    try:
        d = getj(f"{B}/id/stations/{ref}/stageScale", tries=4)
        return ref, d.get("items")
    except Exception as e:
        return ref, None
n = 0
with cf.ThreadPoolExecutor(3) as ex:
    for ref, it in ex.map(one, refs):
        if it: out[ref] = it
        n += 1
        if n % 500 == 0: log(S, f"{n}/{len(refs)} have {len(out)}"); json.dump(out, open(out_p, "w"))
json.dump(out, open(out_p, "w")); save(S, "stagescale_manifest.json", {"n": len(out)}, f"{B}/id/stations/*/stageScale", "OGL-3.0"); log(S, f"done {len(out)}")
