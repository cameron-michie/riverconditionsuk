-- Sites: one row per physical place we measure, discharge from, or survey.
-- The same gauge appears in 4 networks under 4 ids. site_identifier is the crosswalk; merged_into records resolution.

create table core.site (
  id              bigint generated always as identity primary key,
  kind            text not null check (kind in (
                    'river_gauge','rain_gauge','groundwater_station','wq_sampling_point','sonde','bathing_water',
                    'storm_overflow','sewage_works','consented_discharge','survey_site','weather_station','other')),
  name            text,
  geom            geometry(Point,4326) not null,
  geom_bng        geometry(Point,27700),                       -- null outside Great Britain
  country         text references ref.country(code),
  operator_id     bigint references ref.organisation(id),
  status          text not null default 'unknown' check (status in ('active','suspended','closed','unknown')),
  opened_on       date,
  closed_on       date,
  -- spatial context, derived by snapping to the network
  river_link_id   bigint references core.river_link(id),
  river_id        bigint references core.river(id),
  waterbody_id    bigint references core.waterbody(id),
  snap_distance_m real,                                        -- how far we moved it to reach the line: low = trustworthy
  dist_to_mouth_m double precision,                            -- chainage; enables "everything upstream of here"
  river_name_raw  text,                                        -- what the source called the river (kept, never trusted)
  merged_into     bigint references core.site(id),            -- non-null = duplicate of another site
  primary_source_id bigint references ingest.source(id),
  attrs           jsonb not null default '{}',
  check (merged_into is distinct from id)
);
create index on core.site (kind) where merged_into is null;
create index on core.site (operator_id);
create index on core.site (river_link_id);
create index on core.site (river_id);
create index on core.site (waterbody_id);
create index on core.site (merged_into) where merged_into is not null;
create index on core.site (primary_source_id);
create index on core.site using gist (geom);
create index on core.site using gist (geom_bng);
create index on core.site using gin (name gin_trgm_ops);

create table core.site_identifier (
  scheme       text not null,                  -- 'ea_flood:stationReference' | 'ea_hydro:guid' | 'wiski' | 'rloi' | 'nrfa:id' | 'sepa:station_no' | 'ea_wims:notation' | 'nsoh:id' | 'eubwid' | 'permit'
  value        text not null,
  site_id      bigint not null references core.site(id),
  source_id    bigint references ingest.source(id),
  match_method text not null default 'native' check (match_method in ('native','crosswalk','spatial','manual','agent')),
  confidence   real not null default 1,
  primary key (scheme, value)
);
create index on core.site_identifier (site_id);
create index on core.site_identifier (source_id);

-- Entity-resolution audit trail: why two sites were (not) merged. Reversible by design.
create table core.site_match (
  id          bigint generated always as identity primary key,
  site_a      bigint not null references core.site(id),
  site_b      bigint not null references core.site(id),
  score       real not null,
  features    jsonb not null,                  -- {shared_ids:[], dist_m:, same_river:, same_kind:, name_sim:}
  decision    text not null check (decision in ('auto_merge','needs_review','rejected','merged','split')),
  decided_by  text,
  decided_at  timestamptz,
  check (site_a < site_b),
  unique (site_a, site_b)
);
create index on core.site_match (site_b);
create index on core.site_match (decision) where decision = 'needs_review';

-- Slow-changing facts per site (NRFA catchment descriptors, land cover fractions, aquifer, datum...)
create table core.site_attribute (
  site_id    bigint not null references core.site(id),
  key        text not null,                    -- 'catchment_area_km2','lcm2020_cropland','bfihost19'
  value_num  double precision,
  value_text text,
  as_of      date,
  source_id  bigint not null references ingest.source(id),
  primary key (site_id, key, source_id)
);
create index on core.site_attribute (source_id);
create index on core.site_attribute (key);
