-- Geography: the statutory spine (waterbodies, catchments) + the physical network (links/nodes) + the human concept (river).

create table core.catchment (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('rbd','management','operational','waterbody_catchment','caba','nutrient_neutrality','sac','other')),
  code        text not null,
  name        text not null,
  parent_id   bigint references core.catchment(id),
  country     text references ref.country(code),
  source_id   bigint references ingest.source(id),
  geom        geometry(MultiPolygon,4326),
  area_km2    double precision,
  attrs       jsonb not null default '{}',
  unique (kind, code)
);
create index on core.catchment (parent_id);
create index on core.catchment (source_id);
create index on core.catchment using gist (geom);
create index on core.catchment using gin (name gin_trgm_ops);

create table core.waterbody (
  id            bigint generated always as identity primary key,
  wb_code       text not null unique,               -- 'GB109054044890' (England/Wales) ; SEPA ids kept in site_identifier-style table below
  name          text not null,
  category      text not null check (category in ('river','lake','canal','transitional','coastal','groundwater','surface_water_transfer')),
  designation   text,                               -- natural | HMWB | AWB
  country       text references ref.country(code),
  rbd_id        bigint references core.catchment(id),
  mancat_id     bigint references core.catchment(id),
  opcat_id      bigint references core.catchment(id),
  catchment_geom geometry(MultiPolygon,4326),       -- the land draining to this waterbody
  line_geom     geometry(MultiLineString,4326),     -- the waterbody itself (rivers/canals)
  area_km2      double precision,
  length_km     double precision,
  source_id     bigint references ingest.source(id),
  attrs         jsonb not null default '{}'
);
create index on core.waterbody (rbd_id);
create index on core.waterbody (mancat_id);
create index on core.waterbody (opcat_id);
create index on core.waterbody (source_id);
create index on core.waterbody using gist (catchment_geom);
create index on core.waterbody using gist (line_geom);
create index on core.waterbody using gin (name gin_trgm_ops);

-- waterbody ids from other schemes (SEPA, NRW cycle-2 ids, old WFD ids) resolve to the one canonical row
create table core.waterbody_identifier (
  scheme       text not null,
  value        text not null,
  waterbody_id bigint not null references core.waterbody(id),
  source_id    bigint references ingest.source(id),
  primary key (scheme, value)
);
create index on core.waterbody_identifier (waterbody_id);

-- OS Open Rivers network. Nodes/links are physical truth; names on them are NOT unique rivers.
create table core.river_node (
  id        bigint generated always as identity primary key,
  os_id     text not null unique,
  category  text check (category in ('source','junction','outlet')),
  geom      geometry(Point,4326) not null,
  geom_bng  geometry(Point,27700) not null
);
create index on core.river_node using gist (geom);
create index on core.river_node using gist (geom_bng);

-- River = the entity people mean ("the Wye"). Built from topology + names, not from name strings alone.
create table core.river (
  id             bigint generated always as identity primary key,
  slug           text not null unique,
  name           text not null,
  name_cy        text,                                -- Welsh form where the network carries one (Afon Gwy)
  parent_river_id bigint references core.river(id),   -- the river this one joins (tributary tree)
  mouth_node_id  bigint references core.river_node(id),
  source_node_id bigint references core.river_node(id),
  length_km      double precision,
  country_set    text[] not null default '{}',
  strahler_max   smallint,
  geom           geometry(MultiLineString,4326),      -- merged, simplified for display
  derived_by     text not null default 'name+topology',
  attrs          jsonb not null default '{}'
);
create index on core.river (parent_river_id);
create index on core.river (mouth_node_id);
create index on core.river (source_node_id);
create index on core.river using gist (geom);
create index on core.river using gin (name gin_trgm_ops);

create table core.river_alias (
  id        bigint generated always as identity primary key,
  river_id  bigint not null references core.river(id),
  alias     text not null,
  lang      text,                                      -- en | cy | gd | historic
  source_id bigint references ingest.source(id),
  unique (river_id, alias)
);
create index on core.river_alias using gin (alias gin_trgm_ops);

create table core.river_link (
  id             bigint generated always as identity primary key,
  os_id          text not null unique,
  river_id       bigint references core.river(id),
  waterbody_id   bigint references core.waterbody(id),    -- spatially assigned
  form           text not null check (form in ('inlandRiver','canal','lake','tidalRiver')),
  name           text,
  name_alt       text,
  length_m       real,
  start_node_id  bigint not null references core.river_node(id),
  end_node_id    bigint not null references core.river_node(id),
  flow_direction text,
  strahler       smallint,                                -- computed from topology
  dist_to_mouth_m double precision,                       -- downstream chainage of the link's end node
  geom           geometry(LineString,4326) not null,
  geom_bng       geometry(LineString,27700) not null
);
create index on core.river_link (river_id);
create index on core.river_link (waterbody_id);
create index on core.river_link (start_node_id);
create index on core.river_link (end_node_id);
create index on core.river_link (name) where name is not null;
create index on core.river_link using gist (geom);
create index on core.river_link using gist (geom_bng);
