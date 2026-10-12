"""Research corpus seed: OpenAlex works about UK rivers (metadata, abstracts, OA status, licences). No full-text."""
from lib import *
S = "research"; U = "https://api.openalex.org/works"
QUERIES = [
 "River Wye phosphorus", "River Wye poultry agriculture nutrient", "Wye catchment water quality", "River Usk water quality phosphate",
 "River Severn catchment nutrients", "River Thames sewage phosphorus", "River Teme water quality", "UK river phosphorus agriculture catchment",
 "storm overflow sewage river ecology United Kingdom", "combined sewer overflow UK river impacts", "UK river algal bloom satellite Sentinel-2",
 "Riverfly macroinvertebrate citizen science UK", "UK rivers citizen science water quality", "diffuse agricultural pollution England rivers",
 "nutrient neutrality catchment England", "Water Framework Directive England river status", "UK river eutrophication chlorophyll phosphorus",
 "intensive livestock manure phosphorus England catchment", "river bathing water E. coli UK inland", "Welsh rivers SAC phosphorus targets",
 "poultry litter phosphorus Herefordshire", "river temperature heatwave UK", "UK river flow drought ecology", "wastewater treatment works phosphorus river UK",
 "Atlantic salmon River Wye decline", "river water quality trends England long-term", "slurry runoff river pollution livestock UK",
]
seen = {}
for q in QUERIES:
    cur, n = "*", 0
    while cur and n < 600:
        j = getj(U, params={"search": q, "per-page": 200, "cursor": cur, "filter": "from_publication_date:1995-01-01",
                            "select": "id,doi,title,display_name,publication_year,publication_date,type,language,open_access,primary_location,best_oa_location,abstract_inverted_index,authorships,cited_by_count,topics,keywords,primary_topic,ids"})
        res = j.get("results", [])
        for w in res:
            w.setdefault("_queries", []); 
            if w["id"] in seen: seen[w["id"]]["_queries"].append(q)
            else: w["_queries"] = [q]; seen[w["id"]] = w
        n += len(res); cur = j.get("meta", {}).get("next_cursor") if res else None
    log(S, f"{q!r}: total unique {len(seen)}")
save(S, "openalex_works.json", list(seen.values()), U, "CC0 (OpenAlex metadata); per-work licences inside")
log(S, f"saved {len(seen)} works")
