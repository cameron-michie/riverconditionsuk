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
supabase/migrations   schema: ingest, ref, core, research, ops, api (42 migrations)
supabase/seed.sql     the rulebook as data: sources, licences, units, parameters, value maps
scripts/collect       one fetcher per source -> data/raw (never edited) + manifest.jsonl
scripts/load          raw -> normalised tables; compute_signals.sql; rebuild_rivers.sh
web                   index.html + app.js (d3 + canvas). No data: everything comes from Supabase tiles.
docs                  NORMALISATION.md (data), MAP.md (how the map scales)
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

Updating is an ETL concern, never the frontend's. Jobs and intervals live in `ops.etl_job`; `scripts/etl/scheduler.py` runs the due ones (call it every minute from launchd, cron or a container; install with `cp scripts/etl/com.riverconditionsuk.etl.plist ~/Library/LaunchAgents/ && launchctl load ~/Library/LaunchAgents/com.riverconditionsuk.etl.plist`). Results are in `ops.etl_run`. The `live` job runs `scripts/load/refresh_live.py`, which brings 'now' up to date (gauge readings, overflow status, flood warnings and outlook, flood index, sewage works). It runs every 15 minutes once the scheduler is installed.

## Not built

No agent runtime, no ETL scheduler (`pg_cron` and `pgmq` are enabled but no jobs are scheduled), no auth. The `ops.proposal` table and the rule-based research links are the seam the agents plug into.
