"""EA Bathing Water Quality: all sites (full view) + in-season samples; classification history."""
from lib import *
S = "bathing"; D = "https://environment.data.gov.uk/doc/bathing-water"
sites, p = [], 0
while True:
    it = getj(f"{D}.json", params={"_pageSize": 50, "_page": p}, timeout=180)["result"]["items"]; sites += it
    if len(it) < 50: break
    p += 1
save(S, "sites_full.json", sites, D, "OGL-3.0"); log(S, f"sites {len(sites)}")
# in-season samples (E. coli / enterococci), newest first back to 2023
out, p, done = [], 0, False
while not done:
    try:
        it = getj("https://environment.data.gov.uk/doc/bathing-water-quality/in-season/sample.json",
                  params={"_pageSize": 500, "_page": p, "_sort": "-sampleDateTime"}, timeout=180)["result"]["items"]
    except Exception as e:
        log(S, f"samples page {p} failed {e}"); break
    for x in it:
        d = x.get("sampleDateTime"); d = d.get("_value") if isinstance(d, dict) else d
        if d and d < "2023-01-01": done = True; break
        out.append(x)
    if len(it) < 500: break
    p += 1
save(S, "in_season_samples_2023_on.json", out, "ea in-season sample", "OGL-3.0"); log(S, f"samples {len(out)}")
