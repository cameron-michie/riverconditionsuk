-- Extensions the schema depends on.
create extension if not exists postgis with schema public;
create extension if not exists pg_trgm with schema public;
create extension if not exists btree_gist with schema public;
create extension if not exists pg_cron;
create extension if not exists pgcrypto with schema extensions;

-- Schemas. Only api is exposed through the Data API (supabase/config.toml).
--   ref   vocabularies, sources and rules: small, seeded, rarely change
--   geo   geometry and places: rivers, waterbodies, areas, sites. Written by the loaders (scripts/load), plus new sites found by ETL jobs
--   live  what the scheduled ETL jobs keep current: series and the last 7 days of readings, site and waterbody state, rain, weather, floods
--   ops   the ETL scheduler, its run log and the cold-archive ledger
--   api   the functions the web app calls
-- core is not declared here: it belongs to the satellite-monitoring work (eo-river-monitor) and holds compat views onto geo for it.
create schema if not exists ref;
create schema if not exists geo;
create schema if not exists live;
create schema if not exists ops;
create schema if not exists api;
