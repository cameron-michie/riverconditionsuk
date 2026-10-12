-- ───────────── flood index and flood likelihood ─────────────
-- Index definitions are data. level: (stage - typical high) / (record max - typical high). flow: flow / QMED (the median annual flood).
create table core.flood_index_rule (kind text not null check (kind in ('level','flow')), from_index numeric not null, band text not null, rank smallint not null, about text not null, primary key (kind, from_index));
insert into core.flood_index_rule values
 ('level', -1000, 'normal',   2, 'within or below its typical range'),
 ('level', 0,     'elevated', 3, 'above its typical range'),
 ('level', 0.5,   'high',     4, 'more than halfway from typical high to the highest level on record'),
 ('level', 0.9,   'severe',   5, 'within 10% of the highest level on record, or above it'),
 ('flow',  -1000, 'normal',   2, 'under 30% of the median annual flood (QMED)'),
 ('flow',  0.3,   'elevated', 3, '30-70% of the median annual flood'),
 ('flow',  0.7,   'high',     4, '70-100% of the median annual flood'),
 ('flow',  1.0,   'severe',   5, 'above the median annual flood (roughly a 1-in-2-year flow or worse)');
alter table core.flood_index_rule enable row level security; create policy public_read on core.flood_index_rule for select to anon, authenticated using (true);

create table core.site_stage_scale (
  site_id bigint primary key references core.site(id),
  datum double precision, typical_low double precision, typical_high double precision,
  highest_recent double precision, highest_recent_at timestamptz, max_on_record double precision, max_on_record_at timestamptz, min_on_record double precision,
  source_id bigint not null references ingest.source(id)
);
create index on core.site_stage_scale (source_id);
alter table core.site_stage_scale enable row level security; create policy public_read on core.site_stage_scale for select to anon, authenticated using (true);

-- current state of every river gauge: height, flow, and how that compares with flood thresholds. Rebuilt by core.refresh_gauge_state().
create table core.gauge_state (
  site_id bigint primary key references core.site(id),
  stage double precision, stage_at timestamptz, typical_low double precision, typical_high double precision, max_on_record double precision, highest_recent double precision, level_index real, level_band text,
  flow double precision, flow_at timestamptz, flow_pct real, qmed double precision, flow_q95 double precision, flow_index real, flow_band text,
  band text not null, band_rank smallint not null, updated_at timestamptz not null default now()
);
create index on core.gauge_state (band_rank);
alter table core.gauge_state enable row level security; create policy public_read on core.gauge_state for select to anon, authenticated using (true);

-- flood likelihood: Flood Forecasting Centre five-day outlook per county / unitary authority
alter table core.boundary drop constraint boundary_kind_check;
alter table core.boundary add constraint boundary_kind_check check (kind in ('country','national_park','city','urban_area','flood_area'));
create table core.flood_forecast (
  statement_id text not null, area_id bigint not null references core.boundary(id), day smallint not null check (day between 1 and 5), forecast_date date not null,
  risk text not null check (risk in ('VL','L','M','H')), codes jsonb not null default '{}', issued_at timestamptz not null, source_id bigint not null references ingest.source(id),
  primary key (statement_id, area_id, day)
);
create index on core.flood_forecast (area_id, forecast_date);
create index on core.flood_forecast (source_id);
alter table core.flood_forecast enable row level security; create policy public_read on core.flood_forecast for select to anon, authenticated using (true);
alter table core.flood_area add column geom_active geometry(MultiPolygon,4326);       -- polygon kept only for areas with an active warning
create index on core.flood_area using gist (geom_active) where geom_active is not null;

-- ───────────── sewage: where it is discharged, and where it is measured ─────────────
create table core.sewage_works (
  id bigint generated always as identity primary key,
  name text, company_id bigint references ref.organisation(id), permit_ref text, receiving_water_raw text,
  geom geometry(Point,4326) not null, geom_bng geometry(Point,27700),
  permit_site_id bigint references core.site(id), monitor_site_id bigint references core.site(id),    -- the permit record, and the effluent sampling point if one exists
  measured boolean not null default false, river_id bigint references core.river(id), waterbody_id bigint references core.waterbody(id),
  attrs jsonb not null default '{}'
);
create index on core.sewage_works using gist (geom);
create index on core.sewage_works (company_id); create index on core.sewage_works (permit_site_id); create index on core.sewage_works (monitor_site_id);
create index on core.sewage_works (river_id); create index on core.sewage_works (waterbody_id);
alter table core.sewage_works enable row level security; create policy public_read on core.sewage_works for select to anon, authenticated using (true);

-- ───────────── bridges drawn as outlines (only the massive ones) ─────────────
create table core.bridge_area (
  id bigint generated always as identity primary key, name text not null, geom geometry(MultiPolygon,4326) not null, length_m integer not null,
  source_id bigint not null references ingest.source(id), source_keys text[] not null default '{}'
);
create index on core.bridge_area using gist (geom); create index on core.bridge_area (source_id);
alter table core.bridge_area enable row level security; create policy public_read on core.bridge_area for select to anon, authenticated using (true);

-- ───────────── layers: name labels belong to layers ─────────────
alter table core.map_layer drop constraint map_layer_grp_check;
alter table core.map_layer add constraint map_layer_grp_check check (grp in ('base','overlay','sewage','points'));
alter table core.map_layer add column has_labels boolean not null default false, add column labels_default boolean not null default false;
update core.map_layer set has_labels = true, labels_default = true where code in ('national_parks','urban','water','beaches');
update core.map_layer set grp = 'overlay', default_on = true, sort = 11 where code = 'water';
update core.map_layer set grp = 'overlay', default_on = true, sort = 12, label = 'beaches' where code = 'beaches';
update core.map_layer set grp = 'sewage', label = 'overflows', sort = 20, default_on = true where code = 'overflows';
update core.map_layer set label = 'gauges', sort = 24, default_on = true, hot_only_below = 8, note = 'river gauges: height, flow and flood index' where code = 'gauges';
update core.map_layer set sort = 10 where code = 'national_parks'; update core.map_layer set sort = 9 where code = 'urban';
insert into core.map_layer (code, label, grp, geom_kind, min_zoom, default_on, sort, max_features, note) values
 ('sewage_works',  'works',       'sewage',  'point',   8, true,  21, 4000, 'water-company treatment works: where treated sewage is discharged; filled = effluent is monitored'),
 ('flood_outlook', 'flood risk',  'overlay', 'polygon', 0, false, 13, 200,  'Flood Forecasting Centre five-day outlook by county / unitary authority'),
 ('flood_warnings','warnings',    'overlay', 'polygon', 0, true,  14, 500,  'active Environment Agency flood warnings and alerts'),
 ('bridge_areas',  'bridges',     'base',    'polygon', 6, true,  3,  200,  'massive bridges drawn as outlines; all other bridges are points');
update core.map_layer set label = 'bridges' where code = 'bridges';
drop table core.map_label_toggle;
