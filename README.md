# River Conditions UK

One schema that reconciles the UK's river data, and a map that annotates it. See `plan.md` for intent, `docs/NORMALISATION.md` for how the data is made consistent.

## Run it

```sh
supabase start -x imgproxy,edge-runtime,logflare,vector,mailpit,realtime,storage-api,gotrue   # db :54322, api :54321
cd web && python3 -m http.server 8000                                                           # http://localhost:8000
```

`supabase db reset` rebuilds the schema and rulebook but **erases the loaded data**. Reload with the steps below (about 10 minutes).
An existing database from before the v2 schema is upgraded in place, keeping its data: `scripts/migrate/v2_upgrade.sh <db-url>`, then run `scripts/etl/archive.py` once.

## Layout

```
supabase/schemas      the schema, declared: ref, geo, live, ops, api (source of truth)
supabase/migrations   generated from the schema files (supabase db schema declarative sync)
supabase/seed.sql     the rulebook as data: sources, units, parameters, vocabularies, bands, map layers, ETL jobs
scripts/migrate       the in-place v2 upgrade, API snapshot/diff, job and loader test harnesses
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
psql "$DATABASE_URL" -f derive_extras.sql -c "select live.retire_inconsistent_series(); select live.flag_implausible();"
python3 load_boundaries.py && python3 load_poi.py && ./rebuild_rivers.sh
python3 fix_operators.py
cd ../collect && PYTHONPATH=.. python3 ea_stagescale.py && PYTHONPATH=.. python3 flood_forecast.py && MIN_GAP=0.5 PYTHONPATH=.. python3 ea_wq_effluent.py
cd ../load && python3 load_flood.py && python3 load_effluent.py && python3 refresh_live.py   # refresh_live.py is the 5-minute job: readings, overflow status, warnings, flood state, flow signals, danger zones
psql "$DATABASE_URL" -f derive_works.sql -f prune_sites.sql && python3 ../etl/build_catchment_cells.py && python3 ../etl/archive.py
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
| `flow_forecast` | 5 min | rain-driven flow forecast for every waterbody (`docs/FLOW_MODEL.md`) |
| `epicollect` | 1 h | Wye Alliance and Usk CaSTCo weekly volunteer readings |
| `ea_hydrology_daily`, `bathing_recent` | 6 h | EA daily flow and rain (7-day window), bathing samples |
| `ea_wq_recent` | 12 h | EA lab chemistry, rolling 45 days |
| `archive` | daily | readings outside the window go to Parquet, verified before deleting |
| `normals` | quarterly | NRFA daily flow to the archive, then seasonal normals rebuilt from it |

## Database

Postgres holds what the map shows now and what the jobs need to keep it current. History lives only in the cold archive.

| schema | holds | tables |
|---|---|---|
| `ref` | vocabularies and rules, seeded | `source` (with its licence), `organisation`, `unit`, `parameter`, `parameter_alias`, `term` (small vocabularies), `signal`, `band`, `map_layer` |
| `geo` | places, built by the loaders | `river`, `river_link`, `waterbody` (latest WFD class per element, reasons, apportionment), `area` (every polygon), `site` (every point, side facts in `attrs`), `site_key`, `gauge_model` |
| `live` | kept current by the jobs | `series` (with its latest reading), `observation`, `site_now` (gauges, overflows, works), `signal`, `waterbody_now` (map strings, flow outlook), `rain`, `weather`, `flood`, `survey` |
| `ops` | the scheduler | `etl_job`, `etl_run` (14 days), `archive_object` |
| `api` | what the web app calls | functions only |

What stays in Postgres: readings from the last 7 days; sparse series keep their last 12 readings (citizen science a year); radar rain 8 days and the newest ECMWF run; surveys 36 months; flood warnings while in force; the latest WFD classification with the cycle before; the latest EDM year with the year before. `scripts/etl/archive.py` moves older readings to `data/archive/` (Storage bucket `archive` when hosted) as Parquet, ledger in `ops.archive_object`. The archive is write-only for the app; only the quarterly `normals` rebuild reads it.

Schema changes: edit `supabase/schemas/*.sql`, then `supabase db schema declarative sync -f <name>` writes the migration. `core` is not declared: it holds the satellite-monitoring tables (`eo-river-monitor` branch) and views onto `geo` for them. Access still to request: `docs/ACCESS.md`.

## Not built

No agent runtime and no auth. Locally the scheduler is an external tick; hosted, `ops.sync_cron()` schedules every job with `pg_cron`.
