# Running the ETL on Supabase Compute (what was built, what was learned)

Status 2026-10-13. Built against the original schema (ingest / ref / core / research / ops / wx / api). The schema-consolidation branch is porting the loaders to ref / geo / live / ops / api; the findings below apply to any layout.

## Architecture
- **Database:** project `cam-rivers` (`thvawsjhxjxwrwyinsly`, eu-west-1). Restored from a local `pg_dump` (the migrations do not replay from empty). `api` exposed through `supabase config push` (only the API service was pushed: schemas `api`, max_rows 5000).
- **Schedule:** `pg_cron` in cam-rivers. `ops.sync_cron()` turns every enabled `ops.etl_job` row into a cron entry (`etl:<job>`) that calls `ops.dispatch_job(name)`. That POSTs `{job, run_id}` through `pg_net` to the compute, with the URL and token from Vault (`etl_url`, `etl_token`). `ops.check_dispatches()` (every 2 min) fails a run whose request was refused and closes dispatched runs that outlive their timeout. **`ops.sync_cron()` has not been run: nothing is scheduled yet.**
- **Compute:** `rivers-etl` in project `ksm-playground` (`hwszyqnmdbspywfeyybx`) because Supabase Compute is private-alpha and only enabled there (`SUPABASE_EXPERIMENTAL_COMPUTE=1 supabase compute ...`). Dockerfile, Python 3.12 on linux/arm64, 4 GB / 2 vCPU. `server.py` takes `POST /run` (header `X-ETL-Token`) and runs the job command from `ops.etl_job` in a background thread via `scheduler.worker`. Deploy: `scripts/deploy_compute.sh` (copies `scripts/` into the build context first).
- **Secrets:** project secrets on ksm-playground (shared with that project's other workloads): `RIVERS_DB_URL` (pooler, session mode), `RIVERS_SUPABASE_URL`, `RIVERS_SERVICE_KEY`, `RIVERS_ETL_TOKEN`, `NRW_*_KEY`. The server maps them to `DATABASE_URL`, `STORAGE_URL`, `STORAGE_KEY`, `EA_PROXY_*`.
- **Storage:** bucket `archive` (private, the Parquet archive, 1,985 files) and `weather` (public, PNG frames). `scripts/etl/store.py` switches between a local folder and Storage by environment.
- **EA proxy:** Edge Function `eaproxy` in cam-rivers (see below).

## Lessons (each one cost a debugging round)
1. **Run `ANALYZE` after `pg_restore`.** Restored tables have no planner statistics; the first heavy job hung for minutes. `analyze` takes seconds.
2. **The compute's egress IP is a US cloud address.** The EA blocks it (403) on `/hydrology`, `/doc/` (linked-data bathing API) and `/spatialdata`; `flood-monitoring`, SEPA, NRFA, ArcGIS, Epicollect, NRW and FFC are fine. `lib.get` routes those three EA paths through `eaproxy`, **and the call must pin `x-region: eu-west-2`**: an Edge Function otherwise runs near its caller (US) and fails the same way.
3. **`eccodes` aborts at interpreter exit on Linux (`free(): invalid pointer`) when imported with the other native libraries.** A job that imports it must `os._exit(0)` after flushing (done in `wx_ifs.py`), otherwise a finished job reports `failed`.
4. **Do not hold a database connection while a job runs.** The pooler closes idle sessions and refuses connects when many clients (this project's other workloads share the pooler) connect at once. `scheduler.worker` reads the command, closes, runs the job, reconnects with backoff to record the result, and logs failures (an exception in a thread is otherwise silent).
5. **Heavy PostGIS on the managed database is slow.** `refresh_flood_zones.py` clipped polygons with `ST_Intersection` inside Postgres and stalled; the clipping now runs in shapely on the compute, results identical (same polygon counts), and it is its own job (`flood_zones`, 15 min) because it takes about two minutes when many warnings are active. It still failed on the compute after 13 minutes with 7 active warnings: not resolved.
6. **Storage MIME types:** the `weather` bucket only accepts `image/png`; `store.put` sets the content type from the file extension.
7. **Redeploying replaces the container.** Runs in flight are lost and their `ops.etl_run` rows stay open; the reaper in `check_dispatches` closes them (only rows it dispatched: another workload logs its own rows in `ops.etl_run`).
8. **NRW Rivers and Seas API:** about ten calls, then HTTP 429 for ~10 s. `nrw_historical.py` paces at one call per 7 s; `nrw_gapfill` failed after 16 minutes on the compute: not resolved.
9. **Compute environment is shared:** every variable of the project is visible to every compute in it.
10. The compute's disk (about 7.6 GB) and the 2-second CPU cap of Edge Functions are why radar, GRIB and Parquet work runs on compute and not in Edge Functions.

## Verified on the compute against the restored database
ok: `live` (1m41s), `wx_radar` (48 s), `wx_ifs` (4.5 min, GRIB decode), `flow_forecast` (1 min), `nrw_telemetry`, `dcww_overflows`, `sepa_extra`, `bathing_recent`, `ea_hydrology_daily`, `epicollect`, `nrw_flood`.
failed: `flood_zones`, `nrw_gapfill`. Not yet run on the compute: `archive`, `flow_normal`, `nrfa_recent`, `ea_wq_recent` (its POST to the EA water-quality API may also be blocked from the compute's IP).

## To go live
`select ops.sync_cron();` in cam-rivers, then stop the laptop LaunchAgent (`launchctl bootout gui/$(id -u)/com.riverconditionsuk.etl`) so two schedulers do not both fetch.
