# Cutting the hosted project (`cam-rivers`) over to the v2 schema and the Compute ETL

Rehearsed end to end on a scratch copy of the hosted database (see PR 3). Not yet run on `cam-rivers`: it modifies a database the satellite-monitoring worker also uses, so it needs an explicit go-ahead.

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
- `flood_zones` took over 13 minutes on the compute with many active warnings (it is now clipped in Python, but the EA tile fetches through the proxy are slow); it has a 25-minute timeout and its own job.
- `nrw_gapfill` failed after 16 minutes against NRW's rate limit; the daily job paces at one call per 7 s and needs a retry on 429.
- `ea_wq_recent` (EA water-quality POST) has not been run from the compute; it may need the proxy.
