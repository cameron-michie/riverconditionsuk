-- The normalisation rulebook, held as data so agents can propose changes and humans can review them.

create table ref.country (
  code text primary key check (code in ('ENG','WLS','SCT','NIR','GB','UK')),
  name text not null
);
insert into ref.country values ('ENG','England'),('WLS','Wales'),('SCT','Scotland'),('NIR','Northern Ireland');

create table ref.organisation (
  id         bigint generated always as identity primary key,
  slug       text not null unique,
  name       text not null,
  kind       text not null check (kind in ('water_company','regulator','charity','university','government','other')),
  country    text,
  aliases    text[] not null default '{}',
  notes      text
);
create index on ref.organisation using gin (aliases);

-- Units: conversion to the canonical unit of the same dimension is  canonical = native * factor + offset
create table ref.unit (
  id           text primary key,                -- 'mg_l'
  label        text not null,
  dimension    text not null,                   -- concentration_mass | flow | length | temperature | ratio | count_per_100ml | depth_rain | conductivity | turbidity | ph | dimensionless
  is_canonical boolean not null default false,
  factor       numeric not null default 1,
  "offset"     numeric not null default 0,
  aliases      text[] not null default '{}'     -- every spelling seen in sources: 'MILLIGRAM PER LITRE','mg/l','mg/L'
);
create unique index ref_unit_one_canonical on ref.unit (dimension) where is_canonical;
create index on ref.unit using gin (aliases);

-- Canonical parameter concepts (what a person means), distinct from source codes (what a lab reports).
create table ref.parameter (
  id             bigint generated always as identity primary key,
  code           text not null unique,          -- 'phosphorus_reactive'
  name           text not null,
  domain         text not null check (domain in ('hydrology','chemistry','biology','bacteria','meteorology','physical','habitat')),
  canonical_unit text references ref.unit(id),
  description    text,
  signal_code    text,                          -- which health sub-signal consumes it: chemical|ecological|algal_visual|...
  higher_is      text check (higher_is in ('worse','better','neutral'))
);
create index on ref.parameter (canonical_unit);

-- Crosswalk: (source, native code) -> canonical parameter + the facets that make 40 "ammonia" codes different things.
create table ref.parameter_alias (
  id              bigint generated always as identity primary key,
  source_id       bigint not null references ingest.source(id),
  native_code     text not null,
  native_label    text,
  native_unit     text,
  parameter_id    bigint references ref.parameter(id),
  unit_id         text references ref.unit(id),
  fraction        text check (fraction in ('total','dissolved','reactive','filtered','unionised','leachable','dry_weight','saturation','load')),
  method          text,                          -- 'in_situ','laboratory','sonde','optical'...
  matrix          text,                          -- 'river_water','effluent','sediment','biota'
  status          text not null default 'unmapped' check (status in ('mapped','unmapped','ignored','review')),
  confidence      real,
  decided_by      text,                          -- 'rule:<id>' | 'human:<who>' | 'agent:<run>'
  note            text,
  unique (source_id, native_code)
);
create index on ref.parameter_alias (parameter_id);
create index on ref.parameter_alias (source_id, status);
create index on ref.parameter_alias using gin (native_label gin_trgm_ops);

-- One generic categorical crosswalk: status/quality/classification vocabularies.
-- domain examples: wfd_status, bathing_class, overflow_status, obs_quality, site_kind, survey_pollution
create table ref.value_map (
  id          bigint generated always as identity primary key,
  domain      text not null,
  source_id   bigint references ingest.source(id),   -- null = applies to every source
  native      text not null,
  canonical   text not null,
  rank        smallint,                               -- ordinal where one exists (1 best .. 5 worst)
  note        text
);
create unique index ref_value_map_uq on ref.value_map (domain, coalesce(source_id, 0), native);
create index on ref.value_map (source_id);

create table ref.classification_element (
  code    text primary key,                           -- 'phosphate','invertebrates','overall','ecological','chemical'
  label   text not null,
  level   text not null check (level in ('overall','ecological','chemical','biological','physico_chemical','hydromorphology','specific_pollutant','priority_substance','other')),
  signal_code text,
  native_names text[] not null default '{}'           -- spellings in CDE / SEPA / NRW
);
create index on ref.classification_element using gin (native_names);

create table ref.pressure_sector (
  code   text primary key,                            -- agriculture | water_industry | urban | ...
  label  text not null,
  native_names text[] not null default '{}'
);
create index on ref.pressure_sector using gin (native_names);
