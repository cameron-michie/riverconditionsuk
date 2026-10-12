"""Catchment Data Explorer national CSVs: RNAGs (reasons for not achieving good), objectives, protected areas."""
import gzip
from lib import *
S = "cde"; B = "https://environment.data.gov.uk/catchment-planning"
for ep in ("rnags", "objectives", "protected-areas"):
    try:
        r = get(f"{B}/England/{ep}.csv", timeout=900)
        save(S, f"england_{ep}.csv.gz", gzip.compress(r.content), r.url, "OGL-3.0"); log(S, f"{ep}: {len(r.content)//1024}KB {r.content[:200]!r}")
    except Exception as e:
        log(S, f"{ep} FAILED {e}")
