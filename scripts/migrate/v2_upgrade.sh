#!/bin/zsh
# One-off upgrade of an existing River Conditions database (local, later the hosted project) to the consolidated v2 schema.
#   scripts/migrate/v2_upgrade.sh <database-url>
# One transaction: move the old schemas aside, create the new ones from the baseline migration, copy and fold the data, drop the old objects,
# then record the baseline as applied so `supabase db push` / `migration up` treat this database as current.
# Afterwards run scripts/etl/archive.py once: it moves readings outside the 7-day window into the cold archive.
# A fresh database does not need this: `supabase db reset` applies the baseline and seed.sql, then the loaders in scripts/load fill geo.
set -euo pipefail
DB=${1:?database url}
HERE=${0:A:h}
ROOT=${HERE:h:h}
BASELINE=$(ls $ROOT/supabase/migrations/*_baseline.sql | head -1)
VERSION=$(basename $BASELINE | cut -d_ -f1)
echo "upgrading with $(basename $BASELINE)"
{
  echo '\set ON_ERROR_STOP on'
  cat $HERE/v2_pre.sql
  # the extensions already exist in an upgraded database
  grep -vE '^(CREATE|COMMENT ON) EXTENSION' $BASELINE
  cat $HERE/v2_data.sql
  echo "create schema if not exists supabase_migrations;"
  echo "create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);"
  echo "delete from supabase_migrations.schema_migrations;"
  echo "insert into supabase_migrations.schema_migrations (version, name) values ('$VERSION', 'baseline');"
} | psql "$DB" -1 -q -v ON_ERROR_STOP=1
psql "$DB" -q -c "vacuum analyze"
echo "done"
