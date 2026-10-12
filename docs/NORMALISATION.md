# Normalisation: how a billion shapes become one river

The data is not the moat; reconciling it is. This documents what the sources actually do (profiled, not assumed), the rules that resolve them, and what is deterministic versus what an agent may only propose.

## 1. What goes wrong, with real examples

| Mismatch | Seen in the data | Rule |
|---|---|---|
| **Same thing, many ids** | One gauge is `3400TH` (EA flood), a UUID (EA hydrology), `39001` (NRFA), a WISKI id and an RLOI id. Overflows: `AnW0194` pre-2024, `AWS00001` after, and in the 2021–23 returns the id column is *empty* on 43,580 rows. | `core.site_identifier(scheme, value) -> site`. Resolve on exact ids first, then the official crosswalk, then composite keys (`company+permit+activity`, `company+WASC permit`, `company+name`). 17,855 station records (5,538 EA flood, 9,537 EA hydrology, 1,604 NRFA, 1,176 SEPA) resolve to 12,031 sites; of the 10,080 sites that carry an EA/NRFA/SEPA id, 3,907 are the same place seen by two or more networks. 72,168 EA annual-return rows plus 14,418 live statuses resolve to 16,544 overflow sites. |
| **Name is not identity** | 600 OS links are called "River Avon", 12 distinct rivers. "River Wye" is three different rivers (the Welsh border Wye, one in Derbyshire, one in Buckinghamshire). The Welsh *Afon Gwy* is the same river as the Wye. | A river is a connected component of same-name links, bridged across unnamed lake/tidal/canal links and merged across component breaks when the next downstream link carries the same name. Slug carries the mouth coordinates. Bilingual aliases are data (`core.river_alias`). |
| **Geometry disagrees** | WQ points, gauges and outfalls sit 100m–2km off the OS line. | KNN snap on the BNG GiST index, accepted only inside a per-kind tolerance; `snap_distance_m` is kept so low trust is visible. Chainage (`dist_to_mouth_m`) is derived so "everything upstream of here" is a query. |
| **Free-text place** | `ReceivingWaterCourse`: "(S) RIVER FROME", "Tributary of Chester Burn", "THE RIVER TOVE", "CAMEL ESTUARY (E)". | Never trusted. Kept as `receiving_water_raw`; place comes from geometry and from the EA's own `wfd_waterbody_id` where supplied. |
| **Parameter semantics** | The EA archive has 8,081 determinands. "Ammonia" alone is ~40 codes (total, un-ionised, filtered, load, dry weight, in situ...). 17 priority codes are mapped by hand; 8,064 are held as `unmapped`. | `ref.parameter` (concept) + `ref.parameter_alias(source, native_code -> parameter, unit, fraction, method, matrix)`. Nothing is dropped; unmapped is a queue an agent proposes into and a human approves. |
| **Units** | `MILLIGRAM PER LITRE`, `mg/l`, `Ml/d`, `mASD` vs `mAOD` vs `mBDAT`, `---`, `V`. | `ref.unit` with factor/offset per dimension and every observed spelling. Values are stored in one canonical unit per parameter; native unit is kept on the series. Levels carry `datum`: not comparable across datums. 347 flood-API measures with unit `---` are rejected, and 35 series whose parameter and unit disagree upstream are retired, not guessed at. |
| **Censoring** | 12.7% of lab results are `<0.03` strings. | `value` is null, `censor='<'`, `detection_limit=0.03`, `value_raw` kept. Nothing averages a detection limit as a reading. 383,880 censored observations stored losslessly. |
| **Sentinels as data** | `#N/A`, empty strings, `-1` status, `0.000\|0.500` (two values in one cell). | Per-field parse rules; `-1` is `offline` ("unknown, not zero"), the pipe case is kept with `quality='suspect'`. Every refusal goes to `ingest.reject` with the reason. |
| **Everything is a string** | The EA annual returns hold counts, hours and percentages as text, and also a `_calculated` twin. | Prefer the `_calculated` numeric where present; keep raw strings in `qualifiers`. |
| **Time** | Lab times are local (Europe/London, naive); feeds are UTC; NRFA daily means are dates; hydrology daily readings are stamped 09:00. | Everything stored `timestamptz` UTC. Naive local times are localised with DST handling. Daily series store the period *start* with `interval_s=86400`. |
| **Categorical vocabularies** | WFD status is `High/Good/Moderate/Poor/Bad` for ecology but `Pass/Fail` for chemistry and `Supports Good` for hydrology. Overflow status is `1/0/-1` for England and `13/14/15/16` for Scotland. | `ref.value_map(domain, source, native -> canonical, rank)`. Ordinal rank only where one exists; pass/fail is never forced onto a 1–5 scale. |
| **Evidence is not equal** | A sonde reading, a company's self-reported spill count, a SEPARATE model share and a Big River Watch "murky" answer are different things. | `core.evidence_class` on every series, signal and survey, carried through to the API and shown beside every figure in the UI. Official, company, regulator, modelled, citizen and research are never merged into one number. |
| **Same fact, two vintages** | WFD classification: cycles 1–3 (2009–2022) in the CDE CSV, cycle 4 (2025) only via CaSTCo; Wales has cycle 3 only. | `core.waterbody_classification` keys on `(waterbody, cycle, year, element, source)`; "current" is the latest cycle; trend compares to the prior cycle. |
| **Silent upstream breakage** | The EA water-quality API was retired in Dec 2025 and rebuilt in Feb 2026 (new paths, JSON-LD capped at 250 rows, CSV at 2,500). EA hosts 403 bursts. | `ingest.source.contract` + `ingest.run` for drift detection; per-host rate limiting in the collectors; `ops.source_health` shows which source went quiet. |

## 2. The ladder

```
raw         data/raw/** + ingest.raw_object (sha256, url, licence)      never edited
stage       per-source adapters: parse, type, reject with reason        ingest.reject
resolve     identity (site), place (river/waterbody), meaning (param/unit/value map)
canonical   core.*  one row per real-world thing, one unit, UTC, evidence_class
derive      core.signal (five named sub-signals, rule in `basis`), rollups
publish     api.* views + RPC; the only schema exposed
```

**Identity ladder for sites**, cheapest and surest first: (1) exact shared id; (2) official crosswalk table; (3) composite key; (4) spatial proximity + same kind + same river; (5) name similarity (`pg_trgm`); (6) agent proposal into `ops.proposal`, human yes/no. Rungs 1–3 are in. Rungs 4–6 write to `core.site_match` with the features that justified them, and every merge is reversible (`merged_into`, never a delete).

## 3. What is deterministic and what an agent may touch

- **Deterministic, in SQL/Python, never an LLM:** unit conversion, censoring, plausibility flags (`ref.parameter.plausible_min/max`), status mapping, signal rules, chainage and snapping.
- **Agent proposes, critic checks, human gates:** `parameter_alias` for the 8,064 unmapped determinands; fuzzy site merges; river aliases; research-to-river geolocation (92 rule-based proposals exist as a baseline to beat); glosses; evidence tags against the human-written taxonomy.
- Nothing an agent writes reaches the `api` schema until its row is `approved`.

## 4. Sources: reality versus the plan

| Source | State | Note |
|---|---|---|
| EA flood monitoring, hydrology, NRFA, WQ archive, bathing, EDM annual, CDE classification and RNAG | **loaded** | Hydrology and WQ hosts 403 above ~1 req/s. |
| Live overflow feeds for all 9 English water companies | **loaded** | One shared "Stream" schema. The two Welsh companies (Dŵr Cymru, Hafren Dyfrdwy): **no open live feed found**, annual returns only. |
| Scottish Water live overflows, SEPA KiWIS | **loaded** | Different schema, own adapter. Scotland has no waterbody polygons in this load, so it shows gauges and overflows but no coloured stretches. |
| Rivers Trust / CaSTCo: Big River Watch, Riverfly (all four variants), SEPARATE P/N/sediment, WFD cycle 4, pollution incidents, obstacles | **loaded** | Licence is per item and several wrap OGL data: confirm before any redistribution or paid tier. |
| OS Open Rivers | **loaded** | The network every site snaps onto. |
| NRW river levels | **blocked** | Azure API portal: needs a free subscription key. |
| NRW Wye sonde data | **blocked** | Only exposed through a permissioned ArcGIS dashboard. The plan calls this the strongest chemistry signal. Email NRW open data. |
| RPA parcel points | **gap** | Points carry only a parcel reference and county: no crop, no land use. Needs CROME or field boundaries. |
| Intensive livestock permits | **gap** | No open dataset. EIR request for the EA permit register. |
| Defra June Survey | **gap** | County level; finest recent geography is 2021. |
| WyeViz, W&UF, Stirling, Cardiff | **gap** | Direct requests, as the plan says. |

## 5. Platform: where Supabase is enough and where it is not

- **Enough:** Postgres + PostGIS + pg_trgm + pgvector, `pg_cron` for schedules, `pgmq` for the adapter queue, RLS + a single `api` schema, PostgREST for the public reads. 31M observations plus 193k PostGIS links ran comfortably locally; bulk loads use `COPY`.
- **Not available, so worked around:** TimescaleDB. Observations use native range partitions (yearly to 2019, monthly after) with BRIN on time and a `(series_id, observed_at)` primary key, plus `observation_latest` and `observation_daily` rollups.
- **Adapters (light):** API pulls fit a small scheduled worker. They need a per-host rate limiter, retry on 403/429/5xx and non-JSON bodies, and idempotent upserts keyed on `(source_id, source_series_key)`.
- **Heavy jobs outside Supabase workers:** the 533MB WFD CSV, satellite scenes and bulk PDF extraction want batch compute that can run for an hour and hold GBs (a container job on Fly/Modal/Cloud Run, or a GitHub Actions runner), writing to Postgres through the same loaders. Park Parquet + DuckDB in front of any backfill larger than a few GB.
- **Map delivery:** the prototype ships simplified GeoJSON (7MB) plus live annotation calls. For the planned MapLibre build, generate PMTiles from `core.waterbody`/`core.river_link` and serve from object storage; keep point layers on the API.
- **Honest limits:** `pg_cron` and `pgmq` are available locally; confirm hosted limits before depending on them for the heavy jobs.

## 6. Decisions that need a human

1. **Sewage reads as "dominant" on the Wye** because the modelled SEPARATE apportionment attributes 51% of phosphorus to sewage works there. The plan expects agriculture to be the Wye's defining pressure. That may be the model's age or its treatment of agricultural load as "mitigated", not the truth. It is shown as `modelled` and should be reviewed before anyone leans on it.
2. **Signal thresholds** (`scripts/load/compute_signals.sql`) are v0 and arbitrary; they should be written down with a reviewer.
3. **Licences** for the Rivers Trust layers and company feeds before any redistribution.
