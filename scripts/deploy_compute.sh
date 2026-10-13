#!/bin/sh
# Build context for the compute: the ETL code is copied in beside the Dockerfile, then deployed to the project that has Supabase Compute enabled.
# Usage: scripts/deploy_compute.sh [project-ref]      (default: the compute project, ksm-playground)
set -e
REF=${1:-hwszyqnmdbspywfeyybx}; D=supabase/compute/rivers-etl
rm -rf $D/app && mkdir -p $D/app
rsync -a --exclude __pycache__ --exclude '*.pyc' scripts/lib.py scripts/load scripts/collect scripts/etl $D/app/scripts/ 2>/dev/null || {
  mkdir -p $D/app/scripts; cp scripts/lib.py $D/app/scripts/; for d in load collect etl; do rsync -a --exclude __pycache__ --exclude '*.pyc' scripts/$d $D/app/scripts/; done; }
cp $D/server.py $D/app/server.py
SUPABASE_EXPERIMENTAL_COMPUTE=1 supabase compute push rivers-etl --project-ref "$REF"
