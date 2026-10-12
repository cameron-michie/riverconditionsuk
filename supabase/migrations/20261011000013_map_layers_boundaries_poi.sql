-- Map as data: layer registry, overlay boundaries, points of interest. The frontend holds no data and no layer list.

-- ───────────── boundaries (towns, cities, national parks, countries) ─────────────
create table core.boundary (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('country','national_park','city','urban_area')),
  code       text not null,
  name       text not null,
  name_alt   text,                                   -- Welsh / Gaelic form
  geom       geometry(MultiPolygon,4326) not null,   -- full detail (BGG generalised by the publisher)
  geom_lo    geometry(MultiPolygon,4326),            -- ~1.5 km tolerance, national view
  geom_mid   geometry(MultiPolygon,4326),            -- ~150 m tolerance, regional view
  label_pt   geometry(Point,4326),
  area_km2   double precision,
  rank       smallint not null default 3,            -- 1 country, 2 city/national park, 3 large town, 4 other
  source_id  bigint references ingest.source(id),
  attrs      jsonb not null default '{}',
  unique (kind, code)
);
create index on core.boundary (kind, rank);
create index on core.boundary (source_id);
create index on core.boundary using gist (geom);
create index on core.boundary using gist (geom_lo);
create index on core.boundary using gist (geom_mid);
create index on core.boundary using gist (label_pt);

-- ───────────── points of interest ─────────────
create table core.poi (
  id            bigint generated always as identity primary key,
  kind          text not null check (kind in ('bridge','reservoir','beach','lock','weir','other')),
  name          text not null,
  geom          geometry(Point,4326) not null,
  geom_bng      geometry(Point,27700),
  source_id     bigint not null references ingest.source(id),
  source_key    text not null,
  river_id      bigint references core.river(id),
  waterbody_id  bigint references core.waterbody(id),
  snap_distance_m real,
  bathing_site_id bigint references core.site(id),   -- beach that is also a designated bathing water
  attrs         jsonb not null default '{}',
  unique (source_id, source_key)
);
create index on core.poi (kind);
create index on core.poi (river_id);
create index on core.poi (waterbody_id);
create index on core.poi (bathing_site_id);
create index on core.poi (source_id);
create index on core.poi using gist (geom);
create index on core.poi using gist (geom_bng);

-- ───────────── layer registry ─────────────
create table core.map_layer (
  code           text primary key,
  label          text not null,                      -- the one word on the toggle
  grp            text not null check (grp in ('base','overlay','points')),
  geom_kind      text not null check (geom_kind in ('line','polygon','point')),
  min_zoom       smallint not null default 0,        -- tile zoom below which the layer is not requested
  cluster_below  smallint,                           -- point layers: below this tile zoom, return grid clusters instead of points
  default_on     boolean not null default false,
  sort           smallint not null default 0,
  max_features   integer not null default 3000,
  note           text
);
insert into core.map_layer (code, label, grp, geom_kind, min_zoom, cluster_below, default_on, sort, max_features, note) values
 ('country',        'countries',    'base',    'polygon', 0, null, true,  0, 50,    'outline'),
 ('network',        'network',      'base',    'line',    0, null, true,  1, 9000,  'all OS watercourses, thinned by Strahler order at low zoom'),
 ('waterbodies',    'condition',    'base',    'line',    0, null, true,  2, 6000,  'coloured by the selected signal'),
 ('national_parks', 'parks',        'overlay', 'polygon', 0, null, false, 10, 40,   null),
 ('urban',          'towns',        'overlay', 'polygon', 4, null, false, 11, 1500, 'cities from zoom 4, large towns from 6, all built-up areas from 8'),
 ('overflows',      'overflows',    'points',  'point',   6, 10,   true,  20, 4000, 'live status; clustered when zoomed out'),
 ('bathing',        'bathing',      'points',  'point',   0, null, true,  21, 800,  'designated bathing waters with official classification'),
 ('gauges',         'flow',         'points',  'point',   6, 9,   false,  22, 3000, 'river flow now against the gauge''s own record'),
 ('beaches',        'beaches',      'points',  'point',   8, 11,  false,  23, 3000, null),
 ('bridges',        'bridges',      'points',  'point',   10, 12, false,  24, 4000, 'named bridges crossing or alongside the river network'),
 ('reservoirs',     'reservoirs',   'points',  'point',   7, 10,  false,  25, 3000, null);

-- ───────────── plain-English signal metadata, held in the database ─────────────
alter table core.signal_def add column short_label text, add column words text[], add column sort smallint, add column is_pressure boolean not null default false;
update core.signal_def set short_label='chemical', words='{good,moderate,poor,bad}', sort=1 where code='chemical';
update core.signal_def set short_label='ecology',  words='{good,moderate,poor,bad}', sort=2 where code='ecological';
update core.signal_def set short_label='sewage',   words='{low,moderate,high,dominant}', sort=3, is_pressure=true where code='sewage_pressure';
update core.signal_def set short_label='farming',  words='{low,moderate,high,dominant}', sort=4, is_pressure=true where code='agricultural_pressure';
update core.signal_def set short_label='algae',    words='{good,moderate,poor,bad}', sort=5 where code='algal_visual';
alter table core.signal add column summary text;     -- one plain sentence saying why, with the source

create table ref.evidence_class_def (code text primary key, label text not null, description text not null, sort smallint not null);
insert into ref.evidence_class_def values
 ('official_monitoring','official','Measured by a regulator or public agency instrument or laboratory.',1),
 ('regulator_assessment','regulator','A formal classification or assessment published by a regulator.',2),
 ('company_reported','company','Reported by the water company itself. Not independently audited.',3),
 ('modelled','modelled','Output of a model. An estimate, not a measurement.',4),
 ('citizen_science','citizen','Volunteer observation.',5),
 ('published_research','research','Published research. Not reviewed by this project.',6),
 ('inferred_risk','inferred','Landscape-level inference. Never attribution to a field or farm.',7);

alter table core.boundary enable row level security; alter table core.poi enable row level security; alter table core.map_layer enable row level security;
alter table ref.evidence_class_def enable row level security;
create policy public_read on core.boundary for select to anon, authenticated using (true);
create policy public_read on core.poi for select to anon, authenticated using (true);
create policy public_read on core.map_layer for select to anon, authenticated using (true);
create policy public_read on ref.evidence_class_def for select to anon, authenticated using (true);
