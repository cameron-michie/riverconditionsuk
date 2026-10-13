# River Conditions UK

One schema that reconciles the UK's river data, and a map that annotates it. See `plan.md` for intent, `docs/NORMALISATION.md` for how the data is made consistent.

## Run it

```sh
supabase start -x imgproxy,edge-runtime,logflare,vector,mailpit,realtime,storage-api,gotrue   # db :54322, api :54321
cd web && python3 -m http.server 8000                                                           # http://localhost:8000
```

`supabase db reset` rebuilds the schema and rulebook but **erases the loaded data**. Reload with the steps below (about 10 minutes).

## Layout

```
supabase/migrations   schema: ingest, ref, core, wx, research, ops, api (63 migrations)
supabase/seed.sql     the rulebook as data: sources, licences, units, parameters, value maps
scripts/collect       one fetcher per source -> data/raw (never edited) + manifest.jsonl
scripts/load          raw -> normalised tables; compute_signals.sql; rebuild_rivers.sh
web                   index.html + app.js (d3 + canvas). No data: everything comes from Supabase tiles.
scripts/etl           scheduler, weather, flow model, archive and the incremental adapters
docs                  NORMALISATION.md (data), MAP.md (map), FLOW_MODEL.md, ACCESS.md (what to request)
data/raw              3.7 GB of source files (git-ignored)
```

## Rebuild the data

```sh
mkdir -p data/raw/basemap && cd data/raw
curl -L -o oprvrs_gpkg_gb.zip "https://api.os.uk/downloads/v1/products/OpenRivers/downloads?area=GB&format=GeoPackage&redirect" && unzip -o oprvrs_gpkg_gb.zip -d osrivers
curl -o wfd_england_classifications.csv "https://environment.data.gov.uk/catchment-planning/England/classifications.csv"   # 533 MB
curl -o basemap/ne_10m_admin_0_map_subunits.geojson https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_admin_0_map_subunits.geojson
cd ../..
cd scripts/collect && for s in sewage sewage2 ea_flood nrfa ea_hydrology bathing ea_wq ea_wq_obs sepa nrw_wfs nrw_wfd rt_castco cde_extra ne_nn boundaries research_openalex; do PYTHONPATH=.. python3 $s.py; done
# EA hosts throttle: run ea_hydrology / ea_wq / ea_wq_obs one at a time, MIN_GAP=0.6 or higher
curl -L -o ../../data/raw/osm/great-britain.osm.pbf https://download.geofabrik.de/europe/great-britain-latest.osm.pbf && PYTHONPATH=.. python3 osm_extract.py   # 2 GB, 2 minutes
cd ../load && python3 load_network.py && python3 derive_rivers.py && python3 load_waterbodies.py && python3 load_sites.py
psql "$DATABASE_URL" -f snap_links_waterbody.sql
./rebuild_rivers.sh        # rivers, river size, snapping, signals; run again whenever derive_rivers.py changes
python3 load_series.py && python3 load_misc.py && python3 load_wales.py && psql "$DATABASE_URL" -f assign_unassigned.sql
psql "$DATABASE_URL" -f derive_extras.sql -c "select ops.retire_inconsistent_series(); select ops.flag_implausible();"
python3 load_boundaries.py && python3 load_poi.py && ./rebuild_rivers.sh
python3 fix_operators.py
cd ../collect && PYTHONPATH=.. python3 ea_stagescale.py && PYTHONPATH=.. python3 flood_forecast.py && MIN_GAP=0.5 PYTHONPATH=.. python3 ea_wq_effluent.py
cd ../load && python3 load_flood.py && python3 load_effluent.py && python3 refresh_live.py   # refresh_live.py is the 15-minute job: readings, overflow status, warnings, flood state, flow signals, danger zones
```

Needs Python 3.14 with `httpx pandas>=3 psycopg[binary] shapely osmium websockets`. Create `data/raw/osm` before the OpenStreetMap download.

## Keeping it live

Updating is an ETL concern, never the frontend's. Jobs and intervals live in `ops.etl_job`. `scripts/etl/scheduler.py` is a tick that starts every due job as its own detached worker, so a slow job never delays a fast one; call it every minute (`cp scripts/etl/com.riverconditionsuk.etl.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.riverconditionsuk.etl.plist`). Jobs use the project venv (`python3 -m venv --system-site-packages .venv && .venv/bin/pip install h5py pillow eccodes scikit-image scipy boto3`), because launchd's PATH finds a Python without the libraries. Results: `ops.etl_run`; health: `select * from ops.job_freshness`.

| job | every | what |
|---|---|---|
| `live` | 5 min | EA readings (all stations), EA/SEPA 15-min flow, 11 company overflow feeds, flood warnings, five-day outlook, flood state, flow signals |
| `dcww_overflows` | 5 min | Welsh Water live overflows (2,362) |
| `wx_radar` | 15 min | Met Office rain radar to map frames and catchment rain |
| `sepa_extra` | 15 min | SEPA stage and hourly rainfall |
| `nrw_telemetry` | 15 min | NRW open telemetry: Welsh river levels and rain gauges (no key needed) |
| `nrw_flood` | 15 min | NRW flood warnings and 3-day flood risk (keys in `.env`; raw responses saved until the schema is known) |
| `nrw_gapfill` | daily | NRW history for any station whose newest reading is over 3 h old (rate limit ~10 calls per window) |
| `wx_ifs` | 1 h | ECMWF five-day rain frames, isobars, catchment rain (loads when a new run lands) |
| `flow_forecast` | 1 h | rain-driven flow forecast for every waterbody and gauge (`docs/FLOW_MODEL.md`) |
| `epicollect` | 1 h | Wye Alliance and Usk CaSTCo weekly volunteer readings |
| `ea_hydrology_daily`, `bathing_recent` | 6 h | EA daily flow and rain (7-day window), bathing samples |
| `ea_wq_recent` | 12 h | EA lab chemistry, rolling 45 days |
| `archive` | daily | rows past their retention go to Parquet (`ops.retention_rule`), verified before deleting |
| `flow_normal` | weekly | seasonal normals, rebuilt from the archive plus hot rows |
| `nrfa_recent` | monthly | NRFA quality-controlled daily flow, straight to the archive |

**Postgres holds now and the next five days.** Observations stay hot for 8 days (15-minute and daily series) or 400 days (lab samples); older rows are archived to `data/archive/` as Parquet laid out like the Storage bucket `archive`, with a ledger in `ops.archive_object`. Forecasts live in `core.forecast` and `core.waterbody_flow`; weather in `wx.*`. Pushing the archive and `web/wx` frames to hosted Supabase Storage is not done yet. Access still to request: `docs/ACCESS.md`.

## Not built

No agent runtime and no auth. The scheduler is an external tick, not `pg_cron` (enabled but unused). The `ops.proposal` table and the rule-based research links are the seam the agents plug into.
