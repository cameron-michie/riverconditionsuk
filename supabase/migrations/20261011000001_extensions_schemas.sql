-- River Conditions UK: foundations.
-- Layering:  ingest (provenance + landing)  ->  ref (vocabularies/crosswalks)  ->  core (normalised entities & facts)
--            research (literature)  ·  ops (agent proposals, health)  ·  api (the ONLY schema exposed to the public).

create extension if not exists postgis;
create extension if not exists pg_trgm;      -- fuzzy name matching for rivers / sites
create extension if not exists btree_gist;
create extension if not exists ltree;
create extension if not exists vector;       -- research embeddings
create extension if not exists pg_cron;      -- scheduled jobs (poll feeds, refresh rollups)
create extension if not exists pgmq;         -- job queue for adapters / agents
create extension if not exists pg_stat_statements;

create schema if not exists ingest;
create schema if not exists ref;
create schema if not exists core;
create schema if not exists research;
create schema if not exists ops;
create schema if not exists api;

comment on schema ingest   is 'Sources, licences, runs and raw landing. Private. Provenance lives here.';
comment on schema ref      is 'Vocabularies and crosswalks (units, parameters, value maps, organisations). The normalisation rulebook as data.';
comment on schema core     is 'Normalised entities and facts. Every row traces to ingest.source. Private; read via api.';
comment on schema research is 'Literature library: works, place links, glosses, evidence tags. Private; read via api.';
comment on schema ops      is 'Agent runs, proposals, human review queue, source health. Private.';
comment on schema api      is 'Public read-only surface (views + RPC). Only schema exposed through PostgREST.';

-- shared evidence vocabulary: the plan requires official / crowd / modelled to be visibly distinguishable
create domain core.evidence_class as text check (value in (
  'official_monitoring',   -- regulator or agency instrument/lab measurement (EA, NRW, SEPA, NRFA)
  'company_reported',      -- water-company self-reported (EDM, effluent self-monitoring)
  'regulator_assessment',  -- derived by a regulator (WFD classification, bathing classification, RNAG)
  'modelled',              -- model output (SEPARATE apportionment, interpolations)
  'citizen_science',       -- volunteer observation (Riverfly, Big River Watch, Water Rangers)
  'published_research',    -- peer reviewed / grey literature
  'inferred_risk'          -- our own landscape-risk inference (never attribution)
));
