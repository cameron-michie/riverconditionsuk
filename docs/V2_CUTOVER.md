# Cutting the hosted project (`cam-rivers`) over to the v2 schema and the Compute ETL

Rehearsed end to end on a scratch copy of the hosted database (see PR 3), then **executed on `cam-rivers` on 2026-10-14** after an explicit go-ahead (it modifies a database the satellite-monitoring worker also uses).

## What was done on 2026-10-14
1. Backup `data/cam_rivers_pre_v2.dump` (465 MB), then `v2_upgrade.sh`: 2.5 minutes, 0 errors. Counts carried over (geo.site 72,008; live.series 120,713; live.survey 76,759; geo.river_link 193,040). The REST `api` layer answers from the new schema.
2. Registry: all jobs present. `eo_worker` was enabled on the hosted project, so `ops.sync_cron()` now skips it (the satellite worker schedules itself).
3. Compute redeployed from PR 3 (image 9.0, later 10.0 with the gap-fill fix).
4. Archive job moved 1,566,205 readings outside the 7-day window into Storage (60 files, ledger 2,044 rows).
5. Smoke tests through pg_cron-style dispatch, all ok: live (1m36s), nrw_telemetry, wx_radar (57 s), wx_ifs (3.5 min), flow_forecast, epicollect, dcww_overflows, sepa_extra, bathing_recent, ea_hydrology_daily, nrw_flood, flood_zones (32 s with 2 risk areas), archive (2m47s).
6. `select ops.sync_cron();` created 18 cron entries; `pg_cron` runs were confirmed unattended.
7. Laptop LaunchAgent stopped.

A dispatch made while the container is restarting returns 502/503; `ops.check_dispatches()` records it as failed and the next tick retries. Avoid redeploying in the middle of a long job (the container is replaced).

## State before
- cam-rivers holds the old layout (ingest / ref / core / research / ops / wx / api) restored from the local database, plus the satellite tables in `core`. `pg_cron` has no jobs. The satellite worker last ran 2026-10-14 00:47 UTC.
- A full backup of those schemas was taken first: `data/cam_rivers_pre_v2.dump` (465 MB, 343 tables of data; restore with `pg_restore --no-owner -d <url>` from a Postgres 17 client).

## Steps (in order)
1. **Upgrade the schema in place.** One transaction, about 30 s; the old `ref`, `ops`, `api` are renamed aside, v2 is created and filled, old objects dropped, `core` (satellite) untouched:
   `zsh scripts/migrate/v2_upgrade.sh "<cam-rivers pooler url, session mode, with password>"`
   Rehearsal on a scratch copy: passed. It needs `ops.etl_run.request_id` to exist (it does on cam-rivers).
2. **Check the registry:** `select name, interval_minutes, enabled from ops.etl_job order by 1;` The upgrade carries over the rows that existed (`flood_zones` is included on cam-rivers; `flow_normal` becomes `normals`). Anything missing is in `supabase/seed.sql`.
3. **Redeploy the compute from this branch** so the container runs the v2 loaders: `scripts/deploy_compute.sh`. (Do it after step 1, never before: the v2 code does not run against the old tables.) Secrets on ksm-playground and Vault entries on cam-rivers are unchanged.
4. **Trim readings once:** dispatch the archive job (`select ops.dispatch_job('archive');`); it moves readings older than the 7-day window to Storage. Check `ops.archive_object`.
5. **Smoke test through the real path:** `select ops.dispatch_job('live');`, then `nrw_telemetry`, `wx_radar`, `wx_ifs`, `flow_forecast`; read `ops.etl_run`.
6. **Schedule:** `select ops.sync_cron();` creates one `pg_cron` entry per enabled job. Run `select * from ops.job_freshness;` after ten minutes.
7. **Stop the laptop scheduler** so two schedulers do not both fetch: `launchctl bootout gui/$(id -u)/com.riverconditionsuk.etl`.

## Rollback
Before step 6: restore `data/cam_rivers_pre_v2.dump` into the project (drop the new schemas first). After step 6: `select cron.unschedule(jobname) from cron.job where jobname like 'etl:%';` stops everything at once.

## Known open items
- `flood_zones` took over 13 minutes on the compute when 7 warnings were active (EA tile fetches through the proxy are slow); with 2 active it takes 30 s. It has a 25-minute timeout and its own job.
- `nrw_gapfill` previously failed because it held a database connection through ~400 rate-limited calls; fixed (fetch with no connection held), verified on the scratch copy.
- `normals` (quarterly: NRFA top-up then seasonal normals from the archive) is slow on first run; watch `ops.job_freshness`.
- `ea_wq_recent` ran ok on the compute.
