#!/bin/zsh
# Run the geo loaders end to end against a scratch database to prove their SQL against the v2 schema.
#   DATABASE_URL=<scratch db> scripts/migrate/test_loaders.sh
# Destructive for that database (it rebuilds areas, waterbody classes, signals, works and prunes sites). Never point it at a database you care about.
set -u
cd ${0:A:h}/../load
PY=../../.venv/bin/python
export PYTHONPATH=..
fail=0
step() { local t0=$SECONDS; echo "── $*"; if "$@" > /tmp/loader_step.log 2>&1; then echo "   ok ($((SECONDS - t0)) s): $(tail -1 /tmp/loader_step.log | cut -c1-200)"; else echo "   FAILED:"; tail -15 /tmp/loader_step.log; fail=1; fi }
step $PY -W ignore load_boundaries.py
step $PY -W ignore load_poi.py
step $PY -W ignore load_waterbodies.py
step $PY -W ignore load_wales.py
step $PY -W ignore load_misc.py
step $PY -W ignore load_flood.py
step $PY -W ignore fix_operators.py
step $PY -W ignore load_effluent.py
step psql $DATABASE_URL -v ON_ERROR_STOP=1 -q -f derive_extras.sql
step psql $DATABASE_URL -v ON_ERROR_STOP=1 -q -f derive_works.sql
step sh rebuild_rivers.sh
step psql $DATABASE_URL -v ON_ERROR_STOP=1 -q -f assign_unassigned.sql
step psql $DATABASE_URL -v ON_ERROR_STOP=1 -q -f prune_sites.sql
echo "done, fail=$fail"
