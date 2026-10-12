# EO worker

Always-on container that watches Sentinel-2 over the UK and writes per-reach satellite evidence to Postgres.
Design and phases: see the plan in the PR description.

## Flow
1. `stac.watch_once` (hourly): Earth Search STAC → `core.scene` → one `pgmq` message (`eo_jobs`) per new scene.
2. `main.worker`: reads a message, `scene_processor.process_scene` scores every observable `core.reach` in the scene,
   writes `core.eo_observation` (idempotent on reach/scene/detector/algo_version), archives the message.
   A crash or error leaves the message to reappear after `VISIBILITY_S`.
3. Every scene is logged in `ops.etl_run` (job `eo_worker`). `/health` on `$PORT` (default 8080).

## Run locally
    supabase migration up            # or psql the 20261012* migrations; never `db reset` (wipes loaded data)
    psql ... -c "select core.build_reaches(); select core.mark_observable();"
    pip install -r requirements.txt
    DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres python -m eo_worker.main

## Tests
    python3 -m unittest discover -s tests      # detector maths, numpy only

## Deploy (Supabase Compute)
    docker build -t eo-worker worker/
Set `DATABASE_URL` (service role / direct connection) as a Compute secret. Never commit it.

## Known limits
- Sentinel-2 only sees reaches wide enough for clean 10–20 m pixels: `core.reach.observable_s2` (≈12% of reaches by the
  Strahler/form prior in `core.mark_observable`). Narrow reaches are "not observable", never guessed.
- Default chl-a calibration is a literature quadratic (Mishra & Mishra 2012). Replace by fitting to EA samples
  (`core.eo_calibration` / `core.eo_matchup`) before presenting numbers as anything but relative.
- Throughput: one windowed read per band per reach is ~25 reaches/min. Next optimisation: read one larger window per
  scene tile block and slice per reach.
- Earth Search C1 L2A reflectance = DN × 0.0001 − 0.1 (processing baseline ≥ 04.00); DN 0 is nodata.
